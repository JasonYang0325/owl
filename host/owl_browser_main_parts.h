// Copyright 2026 AntlerAI. All rights reserved.

#ifndef THIRD_PARTY_OWL_HOST_OWL_BROWSER_MAIN_PARTS_H_
#define THIRD_PARTY_OWL_HOST_OWL_BROWSER_MAIN_PARTS_H_

#include <memory>

#include "content/public/browser/browser_main_parts.h"

namespace display {
class ScreenBase;
}

namespace owl {

class OWLContentBrowserContext;

class OWLBrowserMainParts : public content::BrowserMainParts {
 public:
  OWLBrowserMainParts();
  ~OWLBrowserMainParts() override;

  int PreMainMessageLoopRun() override;
  void PostMainMessageLoopRun() override;

  OWLContentBrowserContext* browser_context() {
    return browser_context_.get();
  }

 private:
  std::unique_ptr<display::ScreenBase> screen_;
  std::unique_ptr<OWLContentBrowserContext> browser_context_;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_BROWSER_MAIN_PARTS_H_
