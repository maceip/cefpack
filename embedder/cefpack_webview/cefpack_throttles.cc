// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cefpack_webview/cefpack_throttles.h"

#include "cefpack_webview/cefpack_session.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "url/gurl.h"

namespace cefpack {

namespace {

bool IsAllowedScheme(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  return url.SchemeIsHTTPOrHTTPS() || url.SchemeIs("about") ||
         url.SchemeIs("data") || url.SchemeIs("blob");
}

bool IsZeroJsBlockedDestination(network::mojom::RequestDestination dest) {
  using Dest = network::mojom::RequestDestination;
  switch (dest) {
    case Dest::kScript:
    case Dest::kWorker:
    case Dest::kSharedWorker:
    case Dest::kServiceWorker:
    case Dest::kAudioWorklet:
    case Dest::kPaintWorklet:
    case Dest::kReport:
    case Dest::kEmbed:
    case Dest::kObject:
    case Dest::kXslt:
      return true;
    default:
      return false;
  }
}

const char* DestinationToResourceType(network::mojom::RequestDestination dest,
                                      bool is_main_frame) {
  using Dest = network::mojom::RequestDestination;
  switch (dest) {
    case Dest::kDocument:
      return is_main_frame ? "main_frame" : "sub_frame";
    case Dest::kIframe:
    case Dest::kFrame:
    case Dest::kFencedframe:
      return "sub_frame";
    case Dest::kStyle:
      return "stylesheet";
    case Dest::kImage:
      return "image";
    case Dest::kFont:
      return "font";
    case Dest::kAudio:
    case Dest::kVideo:
    case Dest::kTrack:
      return "media";
    case Dest::kScript:
      return "script";
    case Dest::kReport:
      return "csp_report";
    default:
      return "other";
  }
}

}  // namespace

CefpackNavigationThrottle::CefpackNavigationThrottle(
    content::NavigationThrottleRegistry& registry)
    : content::NavigationThrottle(registry) {}

CefpackNavigationThrottle::~CefpackNavigationThrottle() = default;

content::NavigationThrottle::ThrottleCheckResult
CefpackNavigationThrottle::WillStartRequest() {
  return CheckNavigation();
}

content::NavigationThrottle::ThrottleCheckResult
CefpackNavigationThrottle::WillRedirectRequest() {
  return CheckNavigation();
}

const char* CefpackNavigationThrottle::GetNameForLogging() {
  return "CefpackNavigationThrottle";
}

content::NavigationThrottle::ThrottleCheckResult
CefpackNavigationThrottle::CheckNavigation() {
  content::NavigationHandle* handle = navigation_handle();
  if (!handle) {
    return BLOCK_REQUEST;
  }
  const GURL& url = handle->GetURL();
  if (!IsAllowedScheme(url)) {
    return BLOCK_REQUEST;
  }

  content::WebContents* web_contents = handle->GetWebContents();
  if (!web_contents) {
    return PROCEED;
  }

  CefpackSession* session = CefpackSession::FromWebContents(web_contents);
  if (!session) {
    return PROCEED;
  }

  const bool is_main_frame = handle->IsInPrimaryMainFrame();
  const std::string top_url =
      is_main_frame ? url.spec() : web_contents->GetVisibleURL().spec();
  const std::string resource_type = is_main_frame ? "main_frame" : "sub_frame";
  const char* method = handle->IsPost() ? "POST" : "GET";
  if (session->ShouldBlockRequest(url.spec(), method, is_main_frame,
                                  resource_type, top_url)) {
    return BLOCK_REQUEST;
  }

  return PROCEED;
}

CefpackURLLoaderThrottle::CefpackURLLoaderThrottle(
    base::RepeatingCallback<content::WebContents*()> wc_getter)
    : wc_getter_(std::move(wc_getter)) {}

CefpackURLLoaderThrottle::~CefpackURLLoaderThrottle() = default;

void CefpackURLLoaderThrottle::WillStartRequest(
    network::ResourceRequest* request,
    bool* defer) {
  if (!request) {
    return;
  }
  last_destination_ = request->destination;
  is_main_frame_ = request->is_outermost_main_frame;
  if (request->site_for_cookies.RepresentativeUrl().is_valid()) {
    top_frame_url_ = request->site_for_cookies.RepresentativeUrl();
  } else if (request->request_initiator.has_value()) {
    top_frame_url_ = request->request_initiator->GetURL();
  }

  if (ShouldBlockUrlAndDestination(request->url, request->method,
                                   is_main_frame_, last_destination_,
                                   top_frame_url_)) {
    delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT, "CefpackZeroJs");
  }
}

void CefpackURLLoaderThrottle::WillRedirectRequest(
    net::RedirectInfo* redirect_info,
    const network::mojom::URLResponseHead& response_head,
    bool* defer,
    network::HttpRequestHeadersUpdateParams* headers_update_params) {
  if (!redirect_info) {
    return;
  }
  if (ShouldBlockUrlAndDestination(redirect_info->new_url,
                                   redirect_info->new_method, is_main_frame_,
                                   last_destination_, top_frame_url_)) {
    delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT, "CefpackZeroJs");
  }
}

bool CefpackURLLoaderThrottle::ShouldBlockUrlAndDestination(
    const GURL& url,
    const std::string& method,
    bool is_main_frame,
    network::mojom::RequestDestination dest,
    const GURL& top_frame_url) {
  if (!IsAllowedScheme(url) || IsZeroJsBlockedDestination(dest)) {
    return true;
  }

  if (content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) &&
      wc_getter_) {
    if (content::WebContents* wc = wc_getter_.Run()) {
      if (CefpackSession* session = CefpackSession::FromWebContents(wc)) {
        const std::string top_spec = top_frame_url.is_valid()
                                         ? top_frame_url.spec()
                                         : wc->GetVisibleURL().spec();
        if (session->ShouldBlockRequest(
                url.spec(), method, is_main_frame,
                DestinationToResourceType(dest, is_main_frame), top_spec)) {
          return true;
        }
      }
    }
  }

  return false;
}

}  // namespace cefpack
