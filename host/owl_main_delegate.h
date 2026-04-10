// Copyright 2026 AntlerAI. All rights reserved.
// OWL Host ContentMainDelegate — minimal Chromium browser process.

#ifndef THIRD_PARTY_OWL_HOST_OWL_MAIN_DELEGATE_H_
#define THIRD_PARTY_OWL_HOST_OWL_MAIN_DELEGATE_H_

#include <memory>
#include <string>
#include <string_view>

#include "base/memory/ref_counted_memory.h"
#include "content/public/app/content_main_delegate.h"
#include "content/public/common/content_client.h"
#include "ui/base/resource/resource_scale_factor.h"
#include "content/public/gpu/content_gpu_client.h"
#include "content/public/renderer/content_renderer_client.h"
#include "content/public/utility/content_utility_client.h"

namespace owl {

class OWLContentBrowserClient;

class OWLMainDelegate : public content::ContentMainDelegate {
 public:
  OWLMainDelegate();
  ~OWLMainDelegate() override;

  // content::ContentMainDelegate:
  std::optional<int> BasicStartupComplete() override;
  void PreSandboxStartup() override;
  std::optional<int> PreBrowserMain() override;
  content::ContentClient* CreateContentClient() override;
  content::ContentBrowserClient* CreateContentBrowserClient() override;
  content::ContentGpuClient* CreateContentGpuClient() override;
  content::ContentRendererClient* CreateContentRendererClient() override;
  content::ContentUtilityClient* CreateContentUtilityClient() override;

 private:
  std::unique_ptr<content::ContentClient> content_client_;
  std::unique_ptr<OWLContentBrowserClient> browser_client_;
  std::unique_ptr<content::ContentGpuClient> gpu_client_;
  std::unique_ptr<content::ContentRendererClient> renderer_client_;
  std::unique_ptr<content::ContentUtilityClient> utility_client_;
};

// ContentClient — bridges Blink resource requests to ui::ResourceBundle.
class OWLContentClient : public content::ContentClient {
 public:
  OWLContentClient();
  ~OWLContentClient() override;
  std::u16string GetLocalizedString(int message_id) override;
  std::string_view GetDataResource(
      int resource_id,
      ui::ResourceScaleFactor scale_factor) override;
  base::RefCountedMemory* GetDataResourceBytes(int resource_id) override;
  std::string GetDataResourceString(int resource_id) override;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_MAIN_DELEGATE_H_
