// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cefpack_webview/cefpack_content_browser_client.h"

#include <utility>

#include "base/command_line.h"
#include "base/posix/global_descriptors.h"
#include "base/strings/string_util.h"
#include "cefpack_webview/cefpack_browser_context.h"
#include "cefpack_webview/cefpack_descriptors.h"
#include "cefpack_webview/cefpack_throttles.h"
#include "content/public/browser/browser_main_parts.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/posix_file_descriptor_info.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/common/content_switches.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/dns/public/dns_over_https_config.h"
#include "net/dns/public/secure_dns_mode.h"
#include "net/proxy_resolution/proxy_config.h"
#include "net/proxy_resolution/proxy_config_with_annotation.h"
#include "net/proxy_resolution/proxy_host_matching_rules.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/cert_verifier/public/mojom/cert_verifier_service_factory.mojom.h"
#include "services/network/public/mojom/host_resolver.mojom.h"
#include "services/network/public/mojom/network_service.mojom.h"
#include "third_party/blink/public/common/switches.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"

namespace cefpack {

namespace {

CefpackContentBrowserClient* g_browser_client = nullptr;

constexpr char kReducedTorUserAgent[] =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/156.0.0.0 Mobile Safari/537.36";

std::string NormalizeSocksProxyRules(const std::string& raw_proxy) {
  std::string trimmed;
  base::TrimWhitespaceASCII(raw_proxy, base::TRIM_ALL, &trimmed);
  if (trimmed.empty()) {
    return "socks5://127.0.0.1:1";
  }
  if (base::StartsWith(trimmed, "socks5h://",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    return "socks5://" + trimmed.substr(10);
  }
  if (trimmed.find("://") == std::string::npos) {
    return "socks5://" + trimmed;
  }
  return trimmed;
}

net::ProxyConfigWithAnnotation BuildSocksProxyConfig(
    const std::string& normalized_rules) {
  net::ProxyConfig config;
  config.proxy_rules().ParseFromString(normalized_rules);
  config.proxy_rules().bypass_rules.AddRulesToSubtractImplicit();
  return net::ProxyConfigWithAnnotation(config, MISSING_TRAFFIC_ANNOTATION);
}

class CefpackBrowserMainParts : public content::BrowserMainParts {
 public:
  explicit CefpackBrowserMainParts(CefpackContentBrowserClient* client)
      : client_(client) {}
  CefpackBrowserMainParts(const CefpackBrowserMainParts&) = delete;
  CefpackBrowserMainParts& operator=(const CefpackBrowserMainParts&) = delete;
  ~CefpackBrowserMainParts() override = default;

  int PreMainMessageLoopRun() override {
    client_->SetActiveBrowserContext(
        std::make_unique<CefpackBrowserContext>());
    return 0;
  }

  void PostMainMessageLoopRun() override { client_->ShutdownContexts(); }

 private:
  raw_ptr<CefpackContentBrowserClient> client_;
};

}  // namespace

// static
CefpackContentBrowserClient* CefpackContentBrowserClient::Get() {
  return g_browser_client;
}

CefpackContentBrowserClient::CefpackContentBrowserClient() {
  g_browser_client = this;
}

CefpackContentBrowserClient::~CefpackContentBrowserClient() {
  if (g_browser_client == this) {
    g_browser_client = nullptr;
  }
}

CefpackBrowserContext* CefpackContentBrowserClient::GetActiveBrowserContext() {
  if (!active_context_) {
    active_context_ = std::make_unique<CefpackBrowserContext>();
  }
  return active_context_.get();
}

void CefpackContentBrowserClient::SetActiveBrowserContext(
    std::unique_ptr<CefpackBrowserContext> context) {
  active_context_ = std::move(context);
}

void CefpackContentBrowserClient::ResetEphemeralContext() {
  if (active_context_) {
    retired_contexts_.push_back(std::move(active_context_));
  }
  active_context_ = std::make_unique<CefpackBrowserContext>();
  ReapUnusedRenderers();
}

void CefpackContentBrowserClient::ReapUnusedRenderers() {
  for (content::RenderProcessHost::iterator it(
           content::RenderProcessHost::AllHostsIterator());
       !it.IsAtEnd(); it.Advance()) {
    content::RenderProcessHost* host = it.GetCurrentValue();
    if (host && host->IsInitializedAndNotDead()) {
      host->FastShutdownIfPossible(/*page_count=*/0,
                                   /*skip_unload_handlers=*/true);
    }
  }
}

void CefpackContentBrowserClient::SetProxyServer(
    const std::string& proxy_server) {
  current_proxy_server_ = NormalizeSocksProxyRules(proxy_server);
  net::ProxyConfigWithAnnotation annotated =
      BuildSocksProxyConfig(current_proxy_server_);
  for (auto& client : proxy_clients_) {
    client->OnProxyConfigUpdated(annotated);
  }
}

void CefpackContentBrowserClient::ShutdownContexts() {
  proxy_clients_.Clear();
  active_context_.reset();
  retired_contexts_.clear();
}

std::unique_ptr<content::BrowserMainParts>
CefpackContentBrowserClient::CreateBrowserMainParts(bool is_integration_test) {
  return std::make_unique<CefpackBrowserMainParts>(this);
}

void CefpackContentBrowserClient::AppendExtraCommandLineSwitches(
    base::CommandLine* command_line,
    int child_process_id) {
  if (!command_line->HasSwitch(blink::switches::kJavaScriptFlags)) {
    command_line->AppendSwitchASCII(blink::switches::kJavaScriptFlags,
                                    "--jitless,--no-expose-wasm");
  }
}

std::string CefpackContentBrowserClient::GetApplicationLocale() {
  return "en-US";
}

std::string CefpackContentBrowserClient::GetAcceptLangs(
    content::BrowserContext* context) {
  return "en-US,en";
}

std::string CefpackContentBrowserClient::GetUserAgent() {
  return kReducedTorUserAgent;
}

void CefpackContentBrowserClient::OverrideWebPreferences(
    content::WebContents* web_contents,
    content::SiteInstance& main_frame_site,
    blink::web_pref::WebPreferences* prefs) {
  if (!prefs) {
    return;
  }
  prefs->javascript_enabled = false;
  prefs->web_security_enabled = true;
  prefs->allow_running_insecure_content = false;
  prefs->webgl1_enabled = false;
  prefs->webgl2_enabled = false;
  prefs->hyperlink_auditing_enabled = false;
}

void CefpackContentBrowserClient::CreateThrottlesForNavigation(
    content::NavigationThrottleRegistry& registry) {
  registry.AddThrottle(std::make_unique<CefpackNavigationThrottle>(registry));
}

std::vector<std::unique_ptr<blink::URLLoaderThrottle>>
CefpackContentBrowserClient::CreateURLLoaderThrottles(
    const network::ResourceRequest& request,
    content::BrowserContext* browser_context,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::NavigationUIData* navigation_ui_data,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id) {
  std::vector<std::unique_ptr<blink::URLLoaderThrottle>> throttles;
  throttles.push_back(std::make_unique<CefpackURLLoaderThrottle>(wc_getter));
  return throttles;
}

void CefpackContentBrowserClient::GetAdditionalMappedFilesForChildProcess(
    const base::CommandLine& command_line,
    int child_process_id,
    content::PosixFileDescriptorInfo* mappings) {
  auto* global_descriptors = base::GlobalDescriptors::GetInstance();
  int pak_fd = global_descriptors->MaybeGet(kCefpackPakDescriptor);
  if (pak_fd >= 0) {
    mappings->ShareWithRegion(
        kCefpackPakDescriptor, pak_fd,
        global_descriptors->GetRegion(kCefpackPakDescriptor));
  }
}

void CefpackContentBrowserClient::OnNetworkServiceCreated(
    network::mojom::NetworkService* network_service) {
  if (!network_service) {
    return;
  }
  network_service->DisableQuic();
  network_service->ConfigureStubHostResolver(
      net::InsecureDnsMode::kDisabled,
      /*happy_eyeballs_v3_enabled=*/false, net::SecureDnsMode::kOff,
      net::DnsOverHttpsConfig(),
      /*additional_dns_types_enabled=*/false,
      /*fallback_doh_nameservers=*/{});
}

void CefpackContentBrowserClient::ConfigureNetworkContextParams(
    content::BrowserContext* context,
    bool in_memory,
    const base::FilePath& relative_partition_path,
    network::mojom::NetworkContextParams* network_context_params,
    cert_verifier::mojom::CertVerifierCreationParams*
        cert_verifier_creation_params) {
  if (!network_context_params) {
    return;
  }
  network_context_params->user_agent = GetUserAgent();
  network_context_params->accept_language = GetAcceptLangs(context);
  network_context_params->http_cache_enabled = false;
  network_context_params->initial_proxy_config =
      BuildSocksProxyConfig(current_proxy_server_);

  mojo::Remote<network::mojom::ProxyConfigClient> proxy_client;
  network_context_params->proxy_config_client_receiver =
      proxy_client.BindNewPipeAndPassReceiver();
  proxy_clients_.Add(std::move(proxy_client));
}

std::vector<base::FilePath>
CefpackContentBrowserClient::GetNetworkContextsParentDirectory() {
  return {GetActiveBrowserContext()->GetPath()};
}

bool CefpackContentBrowserClient::HasErrorPage(int http_status_code) {
  return http_status_code >= 400 && http_status_code < 600;
}

}  // namespace cefpack
