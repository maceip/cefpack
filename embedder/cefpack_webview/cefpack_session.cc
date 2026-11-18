// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cefpack_webview/cefpack_session.h"

#include <cmath>
#include <map>
#include <set>
#include <utility>

#include "base/android/jni_android.h"
#include "base/android/jni_string.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "cefpack_webview/cefpack_browser_context.h"
#include "cefpack_webview/cefpack_content_browser_client.h"
#include "content/public/browser/color_chooser.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "third_party/blink/public/common/mediastream/media_stream_request.h"
#include "third_party/blink/public/common/renderer_preferences/renderer_preferences.h"
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom.h"
#include "third_party/blink/public/mojom/peerconnection/webrtc_ip_handling_policy.mojom.h"

// Must come after all headers that specialize FromJniType() / ToJniType().
#include "cefpack_webview/cefpack_jni_headers/CefpackSession_jni.h"

namespace cefpack {

namespace {

std::set<CefpackSession*>& LiveSessions() {
  static base::NoDestructor<std::set<CefpackSession*>> sessions;
  return *sessions;
}

std::map<content::WebContents*, CefpackSession*>& WebContentsMap() {
  static base::NoDestructor<std::map<content::WebContents*, CefpackSession*>>
      wc_map;
  return *wc_map;
}

class CefpackColorChooser : public content::ColorChooser {
 public:
  CefpackColorChooser() = default;
  ~CefpackColorChooser() override = default;
  void End() override {}
  void SetSelectedColor(SkColor color) override {}
};

}  // namespace

// static
CefpackSession* CefpackSession::FromWebContents(
    content::WebContents* web_contents) {
  if (!web_contents) {
    return nullptr;
  }
  auto& map = WebContentsMap();
  auto it = map.find(web_contents);
  return it != map.end() ? it->second : nullptr;
}

// static
CefpackSession* CefpackSession::FromNativePtr(jlong ptr) {
  if (ptr == 0) {
    return nullptr;
  }
  auto* candidate = reinterpret_cast<CefpackSession*>(ptr);
  auto& live = LiveSessions();
  return live.find(candidate) != live.end() ? candidate : nullptr;
}

CefpackSession::CefpackSession(
    const base::android::JavaRef<jobject>& java_session)
    : java_session_(java_session) {
  LiveSessions().insert(this);

  CefpackContentBrowserClient* browser_client =
      CefpackContentBrowserClient::Get();
  CHECK(browser_client) << "CefpackContentBrowserClient not initialized";
  CefpackBrowserContext* context = browser_client->GetActiveBrowserContext();

  content::WebContents::CreateParams create_params(context);
  create_params.initially_hidden = false;
  web_contents_ = content::WebContents::Create(create_params);
  if (blink::RendererPreferences* renderer_prefs =
          web_contents_->GetMutableRendererPrefs()) {
    renderer_prefs->webrtc_ip_handling_policy =
        blink::mojom::WebRtcIpHandlingPolicy::kDisableNonProxiedUdp;
    renderer_prefs->enable_do_not_track = false;
    web_contents_->SyncRendererPrefs();
  }
  WebContentsMap()[web_contents_.get()] = this;

  web_contents_->SetDelegate(this);
  Observe(web_contents_.get());

  devtools_bridge_ = std::make_unique<CefpackDevToolsBridge>(web_contents_.get());

  JNIEnv* env = base::android::AttachCurrentThread();
  Java_CefpackSession_initWebContents(env, java_session_,
                                      web_contents_->GetJavaWebContents());
}

CefpackSession::~CefpackSession() {
  LiveSessions().erase(this);
  if (devtools_bridge_) {
    devtools_bridge_->Detach();
    devtools_bridge_.reset();
  }
  Observe(nullptr);
  if (web_contents_) {
    web_contents_->SetDelegate(nullptr);
    WebContentsMap().erase(web_contents_.get());
    web_contents_.reset();
  }
}

bool CefpackSession::ShouldBlockRequest(const std::string& url,
                                        const std::string& method,
                                        bool is_main_frame,
                                        const std::string& resource_type,
                                        const std::string& top_level_url) {
  if (!java_session_) {
    return false;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  return Java_CefpackSession_shouldBlockRequestFromNative(
      env, java_session_, base::android::ConvertUTF8ToJavaString(env, url),
      base::android::ConvertUTF8ToJavaString(env, method), is_main_frame,
      base::android::ConvertUTF8ToJavaString(env, resource_type),
      base::android::ConvertUTF8ToJavaString(env, top_level_url));
}

void CefpackSession::SetZoomLevel(double zoom_level) {
  if (!web_contents_) {
    return;
  }
  content::HostZoomMap::SetZoomLevel(web_contents_.get(), zoom_level);
}

void CefpackSession::ResumeMedia() {
  if (!web_contents_) {
    return;
  }
  if (content::MediaSession* media_session =
          content::MediaSession::GetIfExists(web_contents_.get())) {
    media_session->Resume(content::MediaSession::SuspendType::kUI);
  }
}

bool CefpackSession::IsCurrentlyAudible() const {
  return web_contents_ && web_contents_->IsCurrentlyAudible();
}

void CefpackSession::PopulateNavigationEntries(
    JNIEnv* env,
    const base::android::JavaRef<jobject>& out_list) {
  if (!web_contents_ || !out_list) {
    return;
  }
  content::NavigationController& controller = web_contents_->GetController();
  const int count = controller.GetEntryCount();
  const int current_idx = controller.GetCurrentEntryIndex();
  for (int i = 0; i < count; ++i) {
    content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
    if (!entry) {
      continue;
    }
    const std::string url = entry->GetVirtualURL().spec();
    const std::string title = base::UTF16ToUTF8(entry->GetTitle());
    Java_CefpackSession_appendNavEntryFromNative(
        env, out_list, base::android::ConvertUTF8ToJavaString(env, url),
        base::android::ConvertUTF8ToJavaString(env, title), i == current_idx);
  }
}

void CefpackSession::ExecuteDevToolsMethod(int call_id,
                                           const std::string& method,
                                           const std::string& params_json) {
  if (!devtools_bridge_) {
    OnDevToolsResult(call_id, false, "{\"message\":\"Session closed\"}");
    return;
  }
  devtools_bridge_->ExecuteMethod(
      method, params_json,
      base::BindOnce(&CefpackSession::OnDevToolsResult,
                     weak_factory_.GetWeakPtr(), call_id));
}

void CefpackSession::SetDevToolsEventsEnabled(bool enabled) {
  if (!devtools_bridge_) {
    return;
  }
  if (enabled) {
    devtools_bridge_->SetEventCallback(base::BindRepeating(
        &CefpackSession::OnDevToolsEvent, weak_factory_.GetWeakPtr()));
  } else {
    devtools_bridge_->SetEventCallback(CefpackDevToolsBridge::EventCallback());
  }
}

void CefpackSession::ResolveColorChooser(bool selected, int argb_color) {
  if (!web_contents_ || !color_chooser_open_) {
    return;
  }
  color_chooser_open_ = false;
  if (selected) {
    web_contents_->DidChooseColorInColorChooser(
        static_cast<SkColor>(argb_color));
  }
  web_contents_->DidEndColorChooser();
}

void CefpackSession::NavigationStateChanged(
    content::WebContents* source,
    content::InvalidateTypes changed_flags) {
  if (!web_contents_ || !java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  if (changed_flags & content::INVALIDATE_TYPE_URL) {
    std::string visible = web_contents_->GetVisibleURL().spec();
    Java_CefpackSession_onUrlChangedFromNative(
        env, java_session_,
        base::android::ConvertUTF8ToJavaString(env, visible));
  }
  if (changed_flags & content::INVALIDATE_TYPE_TITLE) {
    std::string title = base::UTF16ToUTF8(web_contents_->GetTitle());
    Java_CefpackSession_onTitleChangedFromNative(
        env, java_session_,
        base::android::ConvertUTF8ToJavaString(env, title));
  }
  NotifyLoadingState();
}

void CefpackSession::LoadingStateChanged(content::WebContents* source,
                                         bool should_show_loading_ui) {
  NotifyLoadingState();
}

void CefpackSession::CloseContents(content::WebContents* source) {
  // Tab lifecycle is owned explicitly by TabSessionManager in Java/Kotlin.
}

bool CefpackSession::IsWebContentsCreationOverridden(
    content::RenderFrameHost* opener,
    content::SiteInstance* source_site_instance,
    content::mojom::WindowContainerType window_container_type,
    const GURL& opener_url,
    const std::string& frame_name,
    const GURL& target_url) {
  if (java_session_) {
    JNIEnv* env = base::android::AttachCurrentThread();
    const bool has_gesture =
        opener ? opener->HasTransientUserActivation() : false;
    Java_CefpackSession_onPopupRequestedFromNative(
        env, java_session_,
        base::android::ConvertUTF8ToJavaString(env, target_url.spec()),
        has_gesture);
  }
  // Return true so Chromium calls CreateCustomWebContents() (which defaults to
  // nullptr), suppressing native multi-window WebContents creation while Trap
  // routes user-gesture popups into managed Tor tabs via PopupHandler.
  return true;
}

content::WebContents* CefpackSession::AddNewContents(
    content::WebContents* source,
    std::unique_ptr<content::WebContents> new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
  if (java_session_) {
    JNIEnv* env = base::android::AttachCurrentThread();
    Java_CefpackSession_onPopupRequestedFromNative(
        env, java_session_,
        base::android::ConvertUTF8ToJavaString(env, target_url.spec()),
        user_gesture);
  }
  if (was_blocked) {
    *was_blocked = true;
  }
  return nullptr;
}

void CefpackSession::EnterFullscreenModeForTab(
    content::RenderFrameHost* requesting_frame,
    const blink::mojom::FullscreenOptions& options) {
  is_fullscreen_ = true;
  if (java_session_) {
    JNIEnv* env = base::android::AttachCurrentThread();
    Java_CefpackSession_onFullscreenChangedFromNative(env, java_session_, true);
  }
}

void CefpackSession::ExitFullscreenModeForTab(
    content::WebContents* web_contents) {
  is_fullscreen_ = false;
  if (java_session_) {
    JNIEnv* env = base::android::AttachCurrentThread();
    Java_CefpackSession_onFullscreenChangedFromNative(env, java_session_,
                                                      false);
  }
}

bool CefpackSession::IsFullscreenForTabOrPending(
    const content::WebContents* web_contents) {
  return is_fullscreen_;
}

bool CefpackSession::HandleContextMenu(
    content::RenderFrameHost& render_frame_host,
    const content::ContextMenuParams& params) {
  if (!java_session_) {
    return false;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  const std::string link_url = params.link_url.spec();
  const std::string src_url = params.src_url.spec();
  const std::string selection = base::UTF16ToUTF8(params.selection_text);
  return Java_CefpackSession_onContextMenuFromNative(
      env, java_session_,
      base::android::ConvertUTF8ToJavaString(env, link_url),
      base::android::ConvertUTF8ToJavaString(env, src_url),
      base::android::ConvertUTF8ToJavaString(env, selection));
}

std::unique_ptr<content::ColorChooser> CefpackSession::OpenColorChooser(
    content::WebContents* web_contents,
    SkColor color,
    const std::vector<blink::mojom::ColorSuggestionPtr>& suggestions) {
  if (!java_session_) {
    web_contents->DidEndColorChooser();
    return nullptr;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  color_chooser_open_ = true;
  const bool handled = Java_CefpackSession_onColorChooserFromNative(
      env, java_session_, static_cast<jint>(color));
  if (!handled) {
    color_chooser_open_ = false;
    web_contents->DidEndColorChooser();
    return nullptr;
  }
  return std::make_unique<CefpackColorChooser>();
}

void CefpackSession::RequestMediaAccessPermission(
    content::WebContents* web_contents,
    const content::MediaStreamRequest& request,
    content::MediaResponseCallback callback) {
  if (java_session_) {
    JNIEnv* env = base::android::AttachCurrentThread();
    Java_CefpackSession_onMediaAccessChangedFromNative(env, java_session_,
                                                       false, false);
  }
  std::move(callback).Run(
      blink::mojom::StreamDevicesSet(),
      blink::mojom::MediaStreamRequestResult::PERMISSION_DENIED, nullptr);
}

bool CefpackSession::CheckMediaAccessPermission(
    content::RenderFrameHost* render_frame_host,
    const url::Origin& security_origin,
    blink::mojom::MediaStreamType type) {
  return false;
}

void CefpackSession::DidStartNavigation(
    content::NavigationHandle* navigation_handle) {
  if (!navigation_handle || !navigation_handle->IsInPrimaryMainFrame() ||
      !java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  auto j_url = base::android::ConvertUTF8ToJavaString(
      env, navigation_handle->GetURL().spec());
  Java_CefpackSession_onLoadStartFromNative(env, java_session_, j_url);
  Java_CefpackSession_onUrlChangedFromNative(env, java_session_, j_url);
  NotifyLoadingState();
}

void CefpackSession::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  if (!navigation_handle || !java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  const bool is_main = navigation_handle->IsInPrimaryMainFrame();
  const std::string url = navigation_handle->GetURL().spec();
  const net::Error net_err = navigation_handle->GetNetErrorCode();

  if (navigation_handle->HasCommitted()) {
    int status_code = 0;
    if (const net::HttpResponseHeaders* headers =
            navigation_handle->GetResponseHeaders()) {
      status_code = headers->response_code();
    }
    if (is_main) {
      Java_CefpackSession_onUrlChangedFromNative(
          env, java_session_,
          base::android::ConvertUTF8ToJavaString(env, url));
    }
    if (net_err == net::OK) {
      Java_CefpackSession_onLoadEndFromNative(
          env, java_session_, status_code, is_main,
          base::android::ConvertUTF8ToJavaString(env, url));
    } else if (is_main && net_err != net::ERR_ABORTED) {
      Java_CefpackSession_onLoadErrorFromNative(
          env, java_session_, static_cast<jint>(net_err),
          base::android::ConvertUTF8ToJavaString(env,
                                                 net::ErrorToShortString(net_err)),
          base::android::ConvertUTF8ToJavaString(env, url));
    }
  } else if (is_main && net_err != net::OK && net_err != net::ERR_ABORTED) {
    Java_CefpackSession_onLoadErrorFromNative(
        env, java_session_, static_cast<jint>(net_err),
        base::android::ConvertUTF8ToJavaString(env,
                                               net::ErrorToShortString(net_err)),
        base::android::ConvertUTF8ToJavaString(env, url));
  }

  NotifyLoadingState();
}

void CefpackSession::LoadProgressChanged(double progress) {
  if (!java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  int pct = static_cast<int>(std::lround(progress * 100.0));
  if (pct < 0) {
    pct = 0;
  } else if (pct > 100) {
    pct = 100;
  }
  Java_CefpackSession_onLoadingProgressFromNative(env, java_session_, pct);
}

void CefpackSession::DOMContentLoaded(
    content::RenderFrameHost* render_frame_host) {
  if (!render_frame_host || !render_frame_host->IsInPrimaryMainFrame() ||
      !java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  Java_CefpackSession_onDocumentAvailableFromNative(env, java_session_);
}

void CefpackSession::TitleWasSet(content::NavigationEntry* entry) {
  if (!web_contents_ || !java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  const std::string title = base::UTF16ToUTF8(web_contents_->GetTitle());
  Java_CefpackSession_onTitleChangedFromNative(
      env, java_session_, base::android::ConvertUTF8ToJavaString(env, title));
}

void CefpackSession::OnAudioStateChanged(bool audible) {
  if (!java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  Java_CefpackSession_onAudioStateChangedFromNative(env, java_session_,
                                                    audible);
}

void CefpackSession::NotifyLoadingState() {
  if (!web_contents_ || !java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  content::NavigationController& controller = web_contents_->GetController();
  Java_CefpackSession_onLoadingStateFromNative(
      env, java_session_, web_contents_->IsLoading(), controller.CanGoBack(),
      controller.CanGoForward());
}

void CefpackSession::OnDevToolsResult(int call_id,
                                      bool success,
                                      const std::string& json) {
  if (!java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  Java_CefpackSession_onDevToolsResultFromNative(
      env, java_session_, call_id, success,
      base::android::ConvertUTF8ToJavaString(env, json));
}

void CefpackSession::OnDevToolsEvent(const std::string& method,
                                     const std::string& params_json) {
  if (!java_session_) {
    return;
  }
  JNIEnv* env = base::android::AttachCurrentThread();
  Java_CefpackSession_onDevToolsEventFromNative(
      env, java_session_, base::android::ConvertUTF8ToJavaString(env, method),
      base::android::ConvertUTF8ToJavaString(env, params_json));
}

static jlong JNI_CefpackSession_CreateSession(
    JNIEnv* env,
    const base::android::JavaRef<jobject>& java_session) {
  auto* session = new CefpackSession(java_session);
  return reinterpret_cast<jlong>(session);
}

static void JNI_CefpackSession_DestroySession(JNIEnv* env, jlong session_ptr) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    delete session;
  }
}

static void JNI_CefpackSession_SetZoomLevel(JNIEnv* env,
                                            jlong session_ptr,
                                            jdouble zoom_level) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    session->SetZoomLevel(zoom_level);
  }
}

static void JNI_CefpackSession_ResumeMedia(JNIEnv* env, jlong session_ptr) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    session->ResumeMedia();
  }
}

static jboolean JNI_CefpackSession_IsCurrentlyAudible(JNIEnv* env,
                                                      jlong session_ptr) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    return session->IsCurrentlyAudible();
  }
  return false;
}

static void JNI_CefpackSession_PopulateNavigationEntries(
    JNIEnv* env,
    jlong session_ptr,
    const base::android::JavaRef<jobject>& out_list) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    session->PopulateNavigationEntries(env, out_list);
  }
}

static void JNI_CefpackSession_ExecuteDevToolsMethod(
    JNIEnv* env,
    jlong session_ptr,
    jint call_id,
    const base::android::JavaRef<jstring>& method,
    const base::android::JavaRef<jstring>& params_json) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    std::string method_str =
        method ? base::android::ConvertJavaStringToUTF8(env, method)
               : std::string();
    std::string params_str =
        params_json ? base::android::ConvertJavaStringToUTF8(env, params_json)
                    : std::string();
    session->ExecuteDevToolsMethod(call_id, method_str, params_str);
  }
}

static void JNI_CefpackSession_SetDevToolsEventsEnabled(JNIEnv* env,
                                                        jlong session_ptr,
                                                        jboolean enabled) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    session->SetDevToolsEventsEnabled(enabled);
  }
}

static void JNI_CefpackSession_ResolveColorChooser(JNIEnv* env,
                                                   jlong session_ptr,
                                                   jboolean selected,
                                                   jint argb_color) {
  if (CefpackSession* session = CefpackSession::FromNativePtr(session_ptr)) {
    session->ResolveColorChooser(selected, argb_color);
  }
}

}  // namespace cefpack

DEFINE_JNI(CefpackSession)
