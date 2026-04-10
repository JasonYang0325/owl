// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_main_delegate.h"

#include "base/apple/bundle_locations.h"
#include "base/apple/foundation_util.h"
#include "base/command_line.h"
#include "content/public/common/content_switches.h"
#include "base/files/file_path.h"
#include "base/path_service.h"
#include "third_party/owl/host/owl_content_browser_client.h"
#include "third_party/owl/host/owl_content_gpu_client.h"
#include "third_party/owl/host/owl_content_renderer_client.h"
#include "third_party/owl/host/owl_content_utility_client.h"
#include "ui/base/resource/resource_bundle.h"

namespace owl {

OWLMainDelegate::OWLMainDelegate() = default;
OWLMainDelegate::~OWLMainDelegate() = default;

std::optional<int> OWLMainDelegate::BasicStartupComplete() {
  // Run network service and GPU in-process for development.
  // Out-of-process requires proper sandbox/signing not yet set up for OWL.
  // The GPU Helper subprocess crashes with SEGV (CGSMainConnectionID() returns 0
  // when launched without a WindowServer session). The network service subprocess
  // also crashes due to incomplete configuration.
  // Pipeline tests don't catch this because they complete in ~2s — too fast for
  // Chromium to spawn GPU/Network child processes.
  // TODO(AntlerAI): Re-enable OOP once sandbox configuration is complete.
  base::CommandLine* cmd = base::CommandLine::ForCurrentProcess();
  cmd->AppendSwitch(switches::kInProcessGPU);
  cmd->AppendSwitch("network-service-in-process");  // Feature flag, no switch constant
  return std::nullopt;
}

void OWLMainDelegate::PreSandboxStartup() {
  base::FilePath pak_dir;
  if (base::apple::AmIBundled()) {
    // When running as .app bundle, pak files are in the framework's
    // Resources directory. FrameworkBundlePath() returns the .framework
    // root; the Resources symlink resolves through Versions/Current/.
    pak_dir = base::apple::FrameworkBundlePath().Append("Resources");
  } else {
    // Bare executable mode (dev/test) — pak next to executable.
    base::PathService::Get(base::DIR_EXE, &pak_dir);
  }
  ui::ResourceBundle::InitSharedInstanceWithPakPath(
      pak_dir.Append(FILE_PATH_LITERAL("owl_host.pak")));
}

std::optional<int> OWLMainDelegate::PreBrowserMain() {
  return std::nullopt;
}

content::ContentClient* OWLMainDelegate::CreateContentClient() {
  content_client_ = std::make_unique<OWLContentClient>();
  return content_client_.get();
}

content::ContentBrowserClient* OWLMainDelegate::CreateContentBrowserClient() {
  browser_client_ = std::make_unique<OWLContentBrowserClient>();
  return browser_client_.get();
}

content::ContentGpuClient* OWLMainDelegate::CreateContentGpuClient() {
  gpu_client_ = std::make_unique<OWLContentGpuClient>();
  return gpu_client_.get();
}

content::ContentRendererClient* OWLMainDelegate::CreateContentRendererClient() {
  renderer_client_ = std::make_unique<OWLContentRendererClient>();
  return renderer_client_.get();
}

content::ContentUtilityClient* OWLMainDelegate::CreateContentUtilityClient() {
  utility_client_ = std::make_unique<OWLContentUtilityClient>();
  return utility_client_.get();
}

OWLContentClient::OWLContentClient() = default;
OWLContentClient::~OWLContentClient() = default;

std::u16string OWLContentClient::GetLocalizedString(int message_id) {
  return std::u16string();
}

std::string_view OWLContentClient::GetDataResource(
    int resource_id,
    ui::ResourceScaleFactor scale_factor) {
  return ui::ResourceBundle::GetSharedInstance().GetRawDataResourceForScale(
      resource_id, scale_factor);
}

base::RefCountedMemory* OWLContentClient::GetDataResourceBytes(
    int resource_id) {
  return ui::ResourceBundle::GetSharedInstance().LoadDataResourceBytes(
      resource_id);
}

std::string OWLContentClient::GetDataResourceString(int resource_id) {
  return ui::ResourceBundle::GetSharedInstance().LoadDataResourceString(
      resource_id);
}

}  // namespace owl
