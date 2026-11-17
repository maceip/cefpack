// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cefpack_webview/cefpack_browser_context.h"

#include <atomic>

#include "base/files/file_util.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/threading/thread_restrictions.h"
#include "components/keyed_service/content/browser_context_dependency_manager.h"
#include "components/keyed_service/core/dependency_manager.h"
#include "components/keyed_service/core/simple_dependency_manager.h"
#include "components/keyed_service/core/simple_factory_key.h"
#include "components/keyed_service/core/simple_key_map.h"

namespace cefpack {

namespace {
std::atomic<uint64_t> g_ephemeral_epoch{1};
}  // namespace

CefpackBrowserContext::CefpackBrowserContext() {
  base::ScopedAllowBlocking allow_blocking;
  base::FilePath cache_dir;
  if (!base::PathService::Get(base::DIR_CACHE, &cache_dir)) {
    base::GetTempDir(&cache_dir);
  }
  uint64_t epoch = g_ephemeral_epoch.fetch_add(1, std::memory_order_relaxed);
  path_ = cache_dir.AppendASCII("cefpack_otr_" + base::NumberToString(epoch));

  key_ = std::make_unique<SimpleFactoryKey>(path_, /*is_off_the_record=*/true);
  SimpleKeyMap::GetInstance()->Associate(this, key_.get());

  BrowserContextDependencyManager::GetInstance()->CreateBrowserContextServices(
      this);
}

CefpackBrowserContext::~CefpackBrowserContext() {
  NotifyWillBeDestroyed();

  DependencyManager::PerformInterlockedTwoPhaseShutdown(
      BrowserContextDependencyManager::GetInstance(), this,
      SimpleDependencyManager::GetInstance(), key_.get());

  SimpleKeyMap::GetInstance()->Dissociate(this);

  ShutdownStoragePartitions();

  if (!path_.empty()) {
    base::ScopedAllowBlocking allow_blocking;
    base::DeletePathRecursively(path_);
  }
}

base::FilePath CefpackBrowserContext::GetPath() const {
  return path_;
}

std::unique_ptr<content::ZoomLevelDelegate>
CefpackBrowserContext::CreateZoomLevelDelegate(
    const base::FilePath& partition_path) {
  return nullptr;
}

bool CefpackBrowserContext::IsOffTheRecord() {
  return true;
}

content::DownloadManagerDelegate*
CefpackBrowserContext::GetDownloadManagerDelegate() {
  return nullptr;
}

content::BrowserPluginGuestManager* CefpackBrowserContext::GetGuestManager() {
  return nullptr;
}

storage::SpecialStoragePolicy*
CefpackBrowserContext::GetSpecialStoragePolicy() {
  return nullptr;
}

content::PlatformNotificationService*
CefpackBrowserContext::GetPlatformNotificationService() {
  return nullptr;
}

content::PushMessagingService*
CefpackBrowserContext::GetPushMessagingService() {
  return nullptr;
}

content::StorageNotificationService*
CefpackBrowserContext::GetStorageNotificationService() {
  return nullptr;
}

content::SSLHostStateDelegate*
CefpackBrowserContext::GetSSLHostStateDelegate() {
  return nullptr;
}

content::PermissionControllerDelegate*
CefpackBrowserContext::GetPermissionControllerDelegate() {
  return nullptr;
}

content::BackgroundFetchDelegate*
CefpackBrowserContext::GetBackgroundFetchDelegate() {
  return nullptr;
}

content::BackgroundSyncController*
CefpackBrowserContext::GetBackgroundSyncController() {
  return nullptr;
}

content::BrowsingDataRemoverDelegate*
CefpackBrowserContext::GetBrowsingDataRemoverDelegate() {
  return nullptr;
}

content::ContentIndexProvider*
CefpackBrowserContext::GetContentIndexProvider() {
  return nullptr;
}

content::ClientHintsControllerDelegate*
CefpackBrowserContext::GetClientHintsControllerDelegate() {
  return nullptr;
}

content::ReduceAcceptLanguageControllerDelegate*
CefpackBrowserContext::GetReduceAcceptLanguageControllerDelegate() {
  return nullptr;
}

content::OriginTrialsControllerDelegate*
CefpackBrowserContext::GetOriginTrialsControllerDelegate() {
  return nullptr;
}

}  // namespace cefpack
