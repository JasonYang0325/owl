// Copyright 2026 AntlerAI. All rights reserved.
// OWL Host Framework entry point — exported for dlopen by app/helper launchers.
// Modeled after content/shell/app/shell_content_main.cc.

#import <Cocoa/Cocoa.h>

#include <cstring>

#include "content/public/app/content_main.h"
#include "third_party/owl/host/owl_application_mac.h"
#include "third_party/owl/host/owl_main_delegate.h"
#include "third_party/owl/host/owl_paths_mac.h"

// Exported symbol — called by owl_main_mac.cc via dlsym.
__attribute__((visibility("default")))
extern "C" int OWLContentMain(int argc, const char** argv) {
  // Check for --type= argument directly in argv (before CommandLine::Init,
  // which is called inside content::ContentMain).
  bool is_subprocess = false;
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--type=", 7) == 0) {
      is_subprocess = true;
      break;
    }
  }

  if (!is_subprocess) {
    // Only the browser process needs NSApplication (for NativeEventProcessor).
    // Subprocesses (GPU, Renderer, Utility) must not register NSApp.
    [OWLApplication sharedApplication];
  }

  // Override bundle paths before ContentMain — enables Chromium to discover
  // Helper Apps for GPU/Renderer/Utility subprocesses.
  owl::OverrideOWLBundlePaths(is_subprocess);

  owl::OWLMainDelegate delegate;
  content::ContentMainParams params(&delegate);
  params.argc = argc;
  params.argv = argv;
  return content::ContentMain(std::move(params));
}
