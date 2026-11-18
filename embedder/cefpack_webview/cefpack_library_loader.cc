// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "base/android/jni_android.h"
#include "base/android/library_loader/library_loader_hooks.h"
#include "cefpack_webview/cefpack_main_delegate.h"
#include "content/public/app/content_jni_onload.h"
#include "content/public/app/content_main.h"

namespace {

bool CefpackNativeInitializationHook(
    base::android::LibraryProcessType library_process_type) {
  if (!content::android::OnJNIOnLoadInit()) {
    return false;
  }

  content::SetContentMainDelegate(new cefpack::CefpackMainDelegate());
  return true;
}

}  // namespace

JNI_EXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
  base::android::InitVM(vm);
  base::android::SetNativeInitializationHook(&CefpackNativeInitializationHook);
  return JNI_VERSION_1_4;
}
