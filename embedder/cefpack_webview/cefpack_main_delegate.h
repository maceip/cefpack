// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_MAIN_DELEGATE_H_
#define CEFPACK_WEBVIEW_CEFPACK_MAIN_DELEGATE_H_

#include <memory>
#include <optional>
#include <string>
#include <variant>

#include "components/memory_system/memory_system.h"
#include "content/public/app/content_main_delegate.h"

namespace cefpack {

class CefpackContentBrowserClient;
class CefpackContentClient;

class CefpackMainDelegate : public content::ContentMainDelegate {
 public:
  CefpackMainDelegate();
  CefpackMainDelegate(const CefpackMainDelegate&) = delete;
  CefpackMainDelegate& operator=(const CefpackMainDelegate&) = delete;
  ~CefpackMainDelegate() override;

  // content::ContentMainDelegate implementation:
  std::optional<int> BasicStartupComplete() override;
  void PreSandboxStartup() override;
  std::optional<int> PostEarlyInitialization(InvokedIn invoked_in) override;
  std::variant<int, content::MainFunctionParams> RunProcess(
      const std::string& process_type,
      content::MainFunctionParams main_function_params) override;
  content::ContentClient* CreateContentClient() override;
  content::ContentBrowserClient* CreateContentBrowserClient() override;

 private:
  void InitializeResourceBundle();

  std::unique_ptr<CefpackContentClient> content_client_;
  std::unique_ptr<CefpackContentBrowserClient> browser_client_;
  memory_system::MemorySystem memory_system_;
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_MAIN_DELEGATE_H_
