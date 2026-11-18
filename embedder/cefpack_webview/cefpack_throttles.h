// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_THROTTLES_H_
#define CEFPACK_WEBVIEW_CEFPACK_THROTTLES_H_

#include <memory>

#include <string>

#include "base/functional/callback.h"
#include "content/public/browser/navigation_throttle.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "third_party/blink/public/common/loader/url_loader_throttle.h"
#include "url/gurl.h"

namespace content {
class NavigationThrottleRegistry;
class WebContents;
}  // namespace content

namespace cefpack {

class CefpackNavigationThrottle : public content::NavigationThrottle {
 public:
  explicit CefpackNavigationThrottle(
      content::NavigationThrottleRegistry& registry);
  CefpackNavigationThrottle(const CefpackNavigationThrottle&) = delete;
  CefpackNavigationThrottle& operator=(const CefpackNavigationThrottle&) =
      delete;
  ~CefpackNavigationThrottle() override;

  ThrottleCheckResult WillStartRequest() override;
  ThrottleCheckResult WillRedirectRequest() override;
  const char* GetNameForLogging() override;

 private:
  ThrottleCheckResult CheckNavigation();
};

class CefpackURLLoaderThrottle : public blink::URLLoaderThrottle {
 public:
  explicit CefpackURLLoaderThrottle(
      base::RepeatingCallback<content::WebContents*()> wc_getter);
  CefpackURLLoaderThrottle(const CefpackURLLoaderThrottle&) = delete;
  CefpackURLLoaderThrottle& operator=(const CefpackURLLoaderThrottle&) = delete;
  ~CefpackURLLoaderThrottle() override;

  void WillStartRequest(network::ResourceRequest* request,
                        bool* defer) override;
  void WillRedirectRequest(
      net::RedirectInfo* redirect_info,
      const network::mojom::URLResponseHead& response_head,
      bool* defer,
      network::HttpRequestHeadersUpdateParams* headers_update_params) override;

 private:
  bool ShouldBlockUrlAndDestination(const GURL& url,
                                    const std::string& method,
                                    bool is_main_frame,
                                    network::mojom::RequestDestination dest,
                                    const GURL& top_frame_url);

  base::RepeatingCallback<content::WebContents*()> wc_getter_;
  network::mojom::RequestDestination last_destination_ =
      network::mojom::RequestDestination::kEmpty;
  bool is_main_frame_ = false;
  GURL top_frame_url_;
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_THROTTLES_H_
