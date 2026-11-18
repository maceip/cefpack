// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_SESSION_H_
#define CEFPACK_WEBVIEW_CEFPACK_SESSION_H_

#include <memory>
#include <string>
#include <vector>

#include "base/android/scoped_java_ref.h"
#include "base/memory/weak_ptr.h"
#include "cefpack_webview/cefpack_devtools_bridge.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"

namespace cefpack {

class CefpackSession : public content::WebContentsDelegate,
                       public content::WebContentsObserver {
 public:
  explicit CefpackSession(const base::android::JavaRef<jobject>& java_session);
  CefpackSession(const CefpackSession&) = delete;
  CefpackSession& operator=(const CefpackSession&) = delete;
  ~CefpackSession() override;

  static CefpackSession* FromWebContents(content::WebContents* web_contents);
  static CefpackSession* FromNativePtr(jlong ptr);

  content::WebContents* web_contents() const { return web_contents_.get(); }

  bool ShouldBlockRequest(const std::string& url,
                          const std::string& method,
                          bool is_main_frame,
                          const std::string& resource_type,
                          const std::string& top_level_url);

  void SetZoomLevel(double zoom_level);
  void ResumeMedia();
  bool IsCurrentlyAudible() const;
  void PopulateNavigationEntries(
      JNIEnv* env,
      const base::android::JavaRef<jobject>& out_list);
  void ExecuteDevToolsMethod(int call_id,
                             const std::string& method,
                             const std::string& params_json);
  void SetDevToolsEventsEnabled(bool enabled);
  void ResolveColorChooser(bool selected, int argb_color);

  // content::WebContentsDelegate implementation:
  void NavigationStateChanged(content::WebContents* source,
                              content::InvalidateTypes changed_flags) override;
  void LoadingStateChanged(content::WebContents* source,
                           bool should_show_loading_ui) override;
  void CloseContents(content::WebContents* source) override;
  bool IsWebContentsCreationOverridden(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      content::mojom::WindowContainerType window_container_type,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url) override;
  content::WebContents* AddNewContents(
      content::WebContents* source,
      std::unique_ptr<content::WebContents> new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      bool user_gesture,
      bool* was_blocked) override;
  void EnterFullscreenModeForTab(
      content::RenderFrameHost* requesting_frame,
      const blink::mojom::FullscreenOptions& options) override;
  void ExitFullscreenModeForTab(content::WebContents* web_contents) override;
  bool IsFullscreenForTabOrPending(
      const content::WebContents* web_contents) override;
  bool HandleContextMenu(content::RenderFrameHost& render_frame_host,
                         const content::ContextMenuParams& params) override;
  std::unique_ptr<content::ColorChooser> OpenColorChooser(
      content::WebContents* web_contents,
      SkColor color,
      const std::vector<blink::mojom::ColorSuggestionPtr>& suggestions)
      override;
  void RequestMediaAccessPermission(
      content::WebContents* web_contents,
      const content::MediaStreamRequest& request,
      content::MediaResponseCallback callback) override;
  bool CheckMediaAccessPermission(
      content::RenderFrameHost* render_frame_host,
      const url::Origin& security_origin,
      blink::mojom::MediaStreamType type) override;

  // content::WebContentsObserver implementation:
  void DidStartNavigation(
      content::NavigationHandle* navigation_handle) override;
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override;
  void LoadProgressChanged(double progress) override;
  void DOMContentLoaded(content::RenderFrameHost* render_frame_host) override;
  void TitleWasSet(content::NavigationEntry* entry) override;
  void OnAudioStateChanged(bool audible) override;

 private:
  void NotifyLoadingState();
  void OnDevToolsResult(int call_id, bool success, const std::string& json);
  void OnDevToolsEvent(const std::string& method,
                       const std::string& params_json);

  base::android::ScopedJavaGlobalRef<jobject> java_session_;
  std::unique_ptr<content::WebContents> web_contents_;
  std::unique_ptr<CefpackDevToolsBridge> devtools_bridge_;
  bool is_fullscreen_ = false;
  bool color_chooser_open_ = false;

  base::WeakPtrFactory<CefpackSession> weak_factory_{this};
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_SESSION_H_
