// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cefpack_webview/cefpack_main_delegate.h"

#include <tuple>
#include <utility>

#include "base/android/apk_assets.h"
#include "base/check_op.h"
#include "base/command_line.h"
#include "base/files/file.h"
#include "base/files/memory_mapped_file.h"
#include "base/logging.h"
#include "base/logging/logging_settings.h"
#include "base/posix/global_descriptors.h"
#include "base/process/current_process.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "cefpack_webview/cefpack_content_browser_client.h"
#include "cefpack_webview/cefpack_content_client.h"
#include "cefpack_webview/cefpack_descriptors.h"
#include "components/memory_system/initializer.h"
#include "components/memory_system/parameters.h"
#include "content/public/browser/android/compositor.h"
#include "content/public/browser/browser_main_runner.h"
#include "content/public/common/content_switches.h"
#include "ui/base/resource/resource_bundle.h"

namespace cefpack {

namespace {

constexpr char kDisabledFeatures[] =
    "PartitionAllocMemoryTagging,AutofillServerCommunication,"
    "OptimizationHints,Translate,MediaRouter,WebRtcHideLocalIpsWithMdns,"
    "HttpsUpgrades,HttpsFirstBalancedMode,HttpsFirstBalancedModeAutoEnable";

void AppendHardeningSwitches(base::CommandLine& command_line) {
  std::string existing_disabled =
      command_line.GetSwitchValueASCII("disable-features");
  if (existing_disabled.empty()) {
    command_line.AppendSwitchASCII("disable-features", kDisabledFeatures);
  } else {
    std::vector<std::string> merged = base::SplitString(
        existing_disabled, ",", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    for (const std::string& req :
         base::SplitString(kDisabledFeatures, ",", base::TRIM_WHITESPACE,
                           base::SPLIT_WANT_NONEMPTY)) {
      bool present = false;
      for (const std::string& cur : merged) {
        if (cur == req) {
          present = true;
          break;
        }
      }
      if (!present) {
        merged.push_back(req);
      }
    }
    command_line.RemoveSwitch("disable-features");
    command_line.AppendSwitchASCII("disable-features",
                                   base::JoinString(merged, ","));
  }

  if (!command_line.HasSwitch("host-resolver-rules")) {
    command_line.AppendSwitchASCII("host-resolver-rules",
                                   "MAP * ~NOTFOUND , EXCLUDE 127.0.0.1");
  }
  command_line.AppendSwitch("dns-prefetch-disable");
  command_line.AppendSwitch("no-pings");
  command_line.AppendSwitch("disable-background-networking");
  command_line.AppendSwitch("disable-client-side-phishing-detection");
  command_line.AppendSwitch("disable-component-update");
  command_line.AppendSwitch("disable-domain-reliability");
  command_line.AppendSwitch("disable-sync");

  if (!command_line.HasSwitch(switches::kJavaScriptFlags)) {
    command_line.AppendSwitchASCII(switches::kJavaScriptFlags,
                                   "--jitless,--no-expose-wasm");
  }
}

}  // namespace

CefpackMainDelegate::CefpackMainDelegate() = default;
CefpackMainDelegate::~CefpackMainDelegate() = default;

std::optional<int> CefpackMainDelegate::BasicStartupComplete() {
  base::CommandLine& command_line = *base::CommandLine::ForCurrentProcess();
  AppendHardeningSwitches(command_line);

  content::Compositor::Initialize();

  logging::LoggingSettings settings;
  settings.logging_dest = logging::LOG_TO_SYSTEM_DEBUG_LOG;
  logging::InitLogging(settings);
  logging::SetLogItems(/*enable_process_id=*/true,
                       /*enable_thread_id=*/true,
                       /*enable_timestamp=*/true,
                       /*enable_tickcount=*/false);

  return std::nullopt;
}

void CefpackMainDelegate::PreSandboxStartup() {
  InitializeResourceBundle();
}

std::optional<int> CefpackMainDelegate::PostEarlyInitialization(
    InvokedIn invoked_in) {
  const std::string process_type =
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kProcessType);

  memory_system::Initializer()
      .SetDispatcherParameters(
          memory_system::DispatcherParameters::
              PoissonAllocationSamplerInclusion::kEnforce,
          memory_system::DispatcherParameters::
              AllocationTraceRecorderInclusion::kIgnore,
          process_type)
      .Initialize(memory_system_);

  return std::nullopt;
}

std::variant<int, content::MainFunctionParams> CefpackMainDelegate::RunProcess(
    const std::string& process_type,
    content::MainFunctionParams main_function_params) {
  if (!process_type.empty()) {
    return std::move(main_function_params);
  }

  base::CurrentProcess::GetInstance().SetProcessType(
      base::CurrentProcessType::PROCESS_BROWSER);

  std::unique_ptr<content::BrowserMainRunner> main_runner =
      content::BrowserMainRunner::Create();
  int initialize_exit_code =
      main_runner->Initialize(std::move(main_function_params));
  DCHECK_LT(initialize_exit_code, 0)
      << "BrowserMainRunner::Initialize failed in CefpackMainDelegate";
  std::ignore = main_runner.release();
  return 0;
}

content::ContentClient* CefpackMainDelegate::CreateContentClient() {
  content_client_ = std::make_unique<CefpackContentClient>();
  return content_client_.get();
}

content::ContentBrowserClient*
CefpackMainDelegate::CreateContentBrowserClient() {
  browser_client_ = std::make_unique<CefpackContentBrowserClient>();
  return browser_client_.get();
}

void CefpackMainDelegate::InitializeResourceBundle() {
  auto* global_descriptors = base::GlobalDescriptors::GetInstance();
  int pak_fd = global_descriptors->MaybeGet(kCefpackPakDescriptor);
  base::MemoryMappedFile::Region pak_region;
  if (pak_fd >= 0) {
    pak_region = global_descriptors->GetRegion(kCefpackPakDescriptor);
  } else {
    pak_fd = base::android::OpenApkAsset("assets/cefpack_resources.pak",
                                         &pak_region);
    if (pak_fd >= 0) {
      global_descriptors->Set(kCefpackPakDescriptor, pak_fd, pak_region);
    }
  }
  CHECK_GE(pak_fd, 0) << "Failed to open assets/cefpack_resources.pak";
  base::File android_pak_file(pak_fd);
  ui::ResourceBundle::InitSharedInstanceWithPakFileRegion(
      android_pak_file.Duplicate(), pak_region);
  ui::ResourceBundle::GetSharedInstance().AddDataPackFromFileRegion(
      std::move(android_pak_file), pak_region, ui::k100Percent);
}

}  // namespace cefpack
