// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cefpack_webview/cefpack_devtools_bridge.h"

#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/values.h"
#include "content/public/browser/web_contents.h"

namespace cefpack {

CefpackDevToolsBridge::CefpackDevToolsBridge(content::WebContents* web_contents)
    : web_contents_(web_contents) {}

CefpackDevToolsBridge::~CefpackDevToolsBridge() {
  Detach();
}

void CefpackDevToolsBridge::SetEventCallback(EventCallback callback) {
  event_callback_ = std::move(callback);
  if (event_callback_) {
    EnsureAttached();
  }
}

bool CefpackDevToolsBridge::EnsureAttached() {
  if (attached_ && agent_host_) {
    return true;
  }
  if (!web_contents_) {
    return false;
  }
  agent_host_ = content::DevToolsAgentHost::GetOrCreateFor(web_contents_);
  if (!agent_host_) {
    return false;
  }
  attached_ = agent_host_->AttachClient(this);
  return attached_;
}

void CefpackDevToolsBridge::ExecuteMethod(const std::string& method,
                                          const std::string& params_json,
                                          ResultCallback callback) {
  if (!EnsureAttached()) {
    if (callback) {
      std::move(callback).Run(false, "{\"message\":\"DevTools unavailable\"}");
    }
    return;
  }

  const int id = next_command_id_++;
  base::DictValue envelope;
  envelope.Set("id", id);
  envelope.Set("method", method);

  if (!params_json.empty()) {
    std::optional<base::Value> parsed = base::JSONReader::Read(
        params_json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
    if (parsed && parsed->is_dict()) {
      envelope.Set("params", std::move(*parsed).TakeDict());
    } else {
      envelope.Set("params", base::DictValue());
    }
  } else {
    envelope.Set("params", base::DictValue());
  }

  std::optional<std::string> payload = base::WriteJson(envelope);
  if (!payload.has_value()) {
    if (callback) {
      std::move(callback).Run(false, "{\"message\":\"JSON encode failed\"}");
    }
    return;
  }

  if (callback) {
    pending_callbacks_.emplace(id, std::move(callback));
  }

  agent_host_->DispatchProtocolMessage(
      this, base::as_bytes(base::span(*payload)));
}

void CefpackDevToolsBridge::Detach() {
  if (attached_ && agent_host_) {
    agent_host_->DetachClient(this);
  }
  attached_ = false;
  agent_host_.reset();
  web_contents_ = nullptr;

  auto callbacks = std::move(pending_callbacks_);
  pending_callbacks_.clear();
  for (auto& [id, cb] : callbacks) {
    if (cb) {
      std::move(cb).Run(false, "{\"message\":\"DevTools detached\"}");
    }
  }
}

void CefpackDevToolsBridge::DispatchProtocolMessage(
    content::DevToolsAgentHost* agent_host,
    base::span<const uint8_t> message) {
  std::string_view text(reinterpret_cast<const char*>(message.data()),
                        message.size());
  std::optional<base::Value> root =
      base::JSONReader::Read(text, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!root || !root->is_dict()) {
    return;
  }
  const base::DictValue& dict = root->GetDict();

  if (std::optional<int> id = dict.FindInt("id")) {
    auto it = pending_callbacks_.find(*id);
    if (it == pending_callbacks_.end()) {
      return;
    }
    ResultCallback cb = std::move(it->second);
    pending_callbacks_.erase(it);
    if (!cb) {
      return;
    }

    if (const base::DictValue* error_dict = dict.FindDict("error")) {
      std::string err = base::WriteJson(*error_dict).value_or("{}");
      std::move(cb).Run(false, err);
      return;
    }

    if (const base::DictValue* result_dict = dict.FindDict("result")) {
      std::string res = base::WriteJson(*result_dict).value_or("{}");
      std::move(cb).Run(true, res);
      return;
    }

    std::move(cb).Run(true, "{}");
    return;
  }

  if (const std::string* method = dict.FindString("method")) {
    if (event_callback_) {
      std::string params_str = "{}";
      if (const base::DictValue* params_dict = dict.FindDict("params")) {
        params_str = base::WriteJson(*params_dict).value_or("{}");
      }
      event_callback_.Run(*method, params_str);
    }
  }
}

void CefpackDevToolsBridge::AgentHostClosed(
    content::DevToolsAgentHost* agent_host) {
  attached_ = false;
  agent_host_.reset();

  auto callbacks = std::move(pending_callbacks_);
  pending_callbacks_.clear();
  for (auto& [id, cb] : callbacks) {
    if (cb) {
      std::move(cb).Run(false, "{\"message\":\"AgentHost closed\"}");
    }
  }
}

bool CefpackDevToolsBridge::MayAttachToURL(const GURL& url, bool is_webui) {
  return true;
}

bool CefpackDevToolsBridge::MayAttachToRenderFrameHost(
    content::RenderFrameHost* render_frame_host) {
  return true;
}

bool CefpackDevToolsBridge::IsTrusted() {
  return true;
}

bool CefpackDevToolsBridge::UsesBinaryProtocol() {
  return false;
}

}  // namespace cefpack
