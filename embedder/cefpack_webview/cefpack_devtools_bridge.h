// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_DEVTOOLS_BRIDGE_H_
#define CEFPACK_WEBVIEW_CEFPACK_DEVTOOLS_BRIDGE_H_

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "base/containers/span.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"

namespace content {
class WebContents;
}

namespace cefpack {

class CefpackDevToolsBridge : public content::DevToolsAgentHostClient {
 public:
  using ResultCallback =
      base::OnceCallback<void(bool success, const std::string& json)>;
  using EventCallback =
      base::RepeatingCallback<void(const std::string& method,
                                   const std::string& params_json)>;

  explicit CefpackDevToolsBridge(content::WebContents* web_contents);
  CefpackDevToolsBridge(const CefpackDevToolsBridge&) = delete;
  CefpackDevToolsBridge& operator=(const CefpackDevToolsBridge&) = delete;
  ~CefpackDevToolsBridge() override;

  void SetEventCallback(EventCallback callback);
  void ExecuteMethod(const std::string& method,
                     const std::string& params_json,
                     ResultCallback callback);
  void Detach();

  // content::DevToolsAgentHostClient implementation:
  void DispatchProtocolMessage(content::DevToolsAgentHost* agent_host,
                               base::span<const uint8_t> message) override;
  void AgentHostClosed(content::DevToolsAgentHost* agent_host) override;
  bool MayAttachToURL(const GURL& url, bool is_webui) override;
  bool MayAttachToRenderFrameHost(
      content::RenderFrameHost* render_frame_host) override;
  bool IsTrusted() override;
  bool UsesBinaryProtocol() override;

 private:
  bool EnsureAttached();

  raw_ptr<content::WebContents> web_contents_;
  scoped_refptr<content::DevToolsAgentHost> agent_host_;
  bool attached_ = false;
  int next_command_id_ = 1;
  std::map<int, ResultCallback> pending_callbacks_;
  EventCallback event_callback_;
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_DEVTOOLS_BRIDGE_H_
