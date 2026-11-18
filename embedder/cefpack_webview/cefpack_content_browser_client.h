// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_CONTENT_BROWSER_CLIENT_H_
#define CEFPACK_WEBVIEW_CEFPACK_CONTENT_BROWSER_CLIENT_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "build/build_config.h"
#include "content/public/browser/content_browser_client.h"
#include "mojo/public/cpp/bindings/remote_set.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/proxy_config_with_annotation.mojom.h"

namespace cefpack {

class CefpackBrowserContext;

class CefpackContentBrowserClient : public content::ContentBrowserClient {
 public:
  static CefpackContentBrowserClient* Get();

  CefpackContentBrowserClient();
  CefpackContentBrowserClient(const CefpackContentBrowserClient&) = delete;
  CefpackContentBrowserClient& operator=(const CefpackContentBrowserClient&) =
      delete;
  ~CefpackContentBrowserClient() override;

  CefpackBrowserContext* GetActiveBrowserContext();
  void SetActiveBrowserContext(std::unique_ptr<CefpackBrowserContext> context);
  void ResetEphemeralContext();
  void ReapUnusedRenderers();
  void SetProxyServer(const std::string& proxy_server);
  void ShutdownContexts();

  // content::ContentBrowserClient implementation:
  std::unique_ptr<content::BrowserMainParts> CreateBrowserMainParts(
      bool is_integration_test) override;
  void AppendExtraCommandLineSwitches(base::CommandLine* command_line,
                                      int child_process_id) override;
  std::string GetApplicationLocale() override;
  std::string GetAcceptLangs(content::BrowserContext* context) override;
  std::string GetUserAgent() override;
  void OverrideWebPreferences(
      content::WebContents* web_contents,
      content::SiteInstance& main_frame_site,
      blink::web_pref::WebPreferences* prefs) override;
  void CreateThrottlesForNavigation(
      content::NavigationThrottleRegistry& registry) override;
  std::vector<std::unique_ptr<blink::URLLoaderThrottle>>
  CreateURLLoaderThrottles(
      const network::ResourceRequest& request,
      content::BrowserContext* browser_context,
      const base::RepeatingCallback<content::WebContents*()>& wc_getter,
      content::NavigationUIData* navigation_ui_data,
      content::FrameTreeNodeId frame_tree_node_id,
      std::optional<int64_t> navigation_id) override;
  void GetAdditionalMappedFilesForChildProcess(
      const base::CommandLine& command_line,
      int child_process_id,
      content::PosixFileDescriptorInfo* mappings) override;
  void OnNetworkServiceCreated(
      network::mojom::NetworkService* network_service) override;
  void ConfigureNetworkContextParams(
      content::BrowserContext* context,
      bool in_memory,
      const base::FilePath& relative_partition_path,
      network::mojom::NetworkContextParams* network_context_params,
      cert_verifier::mojom::CertVerifierCreationParams*
          cert_verifier_creation_params) override;
  std::vector<base::FilePath> GetNetworkContextsParentDirectory() override;
  bool HasErrorPage(int http_status_code) override;

 private:
  std::string current_proxy_server_ = "socks5://127.0.0.1:1";
  std::unique_ptr<CefpackBrowserContext> active_context_;
  std::vector<std::unique_ptr<CefpackBrowserContext>> retired_contexts_;
  mojo::RemoteSet<network::mojom::ProxyConfigClient> proxy_clients_;
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_CONTENT_BROWSER_CLIENT_H_
