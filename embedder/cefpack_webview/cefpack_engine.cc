// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "base/android/jni_android.h"
#include "base/android/jni_string.h"
#include "base/android/scoped_java_ref.h"
#include "cefpack_webview/cefpack_content_browser_client.h"

// Must come after all headers that specialize FromJniType() / ToJniType().
#include "cefpack_webview/cefpack_jni_headers/CefpackEngine_jni.h"

namespace cefpack {

static void JNI_CefpackEngine_SetProxyServer(
    JNIEnv* env,
    const base::android::JavaRef<jstring>& proxy_server) {
  std::string uri = proxy_server
                        ? base::android::ConvertJavaStringToUTF8(env, proxy_server)
                        : std::string();
  if (auto* client = CefpackContentBrowserClient::Get()) {
    client->SetProxyServer(uri);
  }
}

static void JNI_CefpackEngine_ResetEphemeralContext(JNIEnv* env) {
  if (auto* client = CefpackContentBrowserClient::Get()) {
    client->ResetEphemeralContext();
  }
}

static void JNI_CefpackEngine_ReapUnusedRenderers(JNIEnv* env) {
  if (auto* client = CefpackContentBrowserClient::Get()) {
    client->ReapUnusedRenderers();
  }
}

}  // namespace cefpack

DEFINE_JNI(CefpackEngine)
