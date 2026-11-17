// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_DESCRIPTORS_H_
#define CEFPACK_WEBVIEW_CEFPACK_DESCRIPTORS_H_

#include "content/public/common/content_descriptors.h"

namespace cefpack {

enum : int {
  kCefpackPakDescriptor = kContentIPCDescriptorMax + 1,
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_DESCRIPTORS_H_
