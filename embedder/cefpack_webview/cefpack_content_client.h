// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_CONTENT_CLIENT_H_
#define CEFPACK_WEBVIEW_CEFPACK_CONTENT_CLIENT_H_

#include <string>
#include <string_view>

#include "base/memory/ref_counted_memory.h"
#include "content/public/common/content_client.h"
#include "ui/base/resource/resource_scale_factor.h"

namespace cefpack {

class CefpackContentClient : public content::ContentClient {
 public:
  CefpackContentClient();
  ~CefpackContentClient() override;

  std::u16string GetLocalizedString(int message_id) override;
  std::string_view GetDataResource(
      int resource_id,
      ui::ResourceScaleFactor scale_factor) override;
  scoped_refptr<base::RefCountedMemory> GetDataResourceBytes(
      int resource_id) override;
  std::string GetDataResourceString(int resource_id) override;
  gfx::Image& GetNativeImageNamed(int resource_id) override;
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_CONTENT_CLIENT_H_
