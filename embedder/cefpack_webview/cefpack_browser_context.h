// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEFPACK_WEBVIEW_CEFPACK_BROWSER_CONTEXT_H_
#define CEFPACK_WEBVIEW_CEFPACK_BROWSER_CONTEXT_H_

#include <memory>

#include "base/files/file_path.h"
#include "content/public/browser/browser_context.h"

class SimpleFactoryKey;

namespace cefpack {

class CefpackBrowserContext : public content::BrowserContext {
 public:
  CefpackBrowserContext();
  CefpackBrowserContext(const CefpackBrowserContext&) = delete;
  CefpackBrowserContext& operator=(const CefpackBrowserContext&) = delete;
  ~CefpackBrowserContext() override;

  // content::BrowserContext implementation:
  base::FilePath GetPath() const override;
  std::unique_ptr<content::ZoomLevelDelegate> CreateZoomLevelDelegate(
      const base::FilePath& partition_path) override;
  bool IsOffTheRecord() override;
  content::DownloadManagerDelegate* GetDownloadManagerDelegate() override;
  content::BrowserPluginGuestManager* GetGuestManager() override;
  storage::SpecialStoragePolicy* GetSpecialStoragePolicy() override;
  content::PlatformNotificationService* GetPlatformNotificationService()
      override;
  content::PushMessagingService* GetPushMessagingService() override;
  content::StorageNotificationService* GetStorageNotificationService() override;
  content::SSLHostStateDelegate* GetSSLHostStateDelegate() override;
  content::PermissionControllerDelegate* GetPermissionControllerDelegate()
      override;
  content::BackgroundFetchDelegate* GetBackgroundFetchDelegate() override;
  content::BackgroundSyncController* GetBackgroundSyncController() override;
  content::BrowsingDataRemoverDelegate* GetBrowsingDataRemoverDelegate()
      override;
  content::ContentIndexProvider* GetContentIndexProvider() override;
  content::ClientHintsControllerDelegate* GetClientHintsControllerDelegate()
      override;
  content::ReduceAcceptLanguageControllerDelegate*
  GetReduceAcceptLanguageControllerDelegate() override;
  content::OriginTrialsControllerDelegate* GetOriginTrialsControllerDelegate()
      override;

 private:
  base::FilePath path_;
  std::unique_ptr<SimpleFactoryKey> key_;
};

}  // namespace cefpack

#endif  // CEFPACK_WEBVIEW_CEFPACK_BROWSER_CONTEXT_H_
