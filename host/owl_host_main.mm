// Copyright 2026 AntlerAI. All rights reserved.
// OWL Host entry point — bare executable for dev/test.
// The bundled mode uses owl_content_main.mm (in the framework) instead.

#import <Cocoa/Cocoa.h>

#include "content/public/app/content_main.h"
#include "third_party/owl/host/owl_application_mac.h"
#include "third_party/owl/host/owl_main_delegate.h"

int main(int argc, const char** argv) {
  // Register OWLApplication as NSApp before ContentMain.
  // Required for NativeEventProcessor protocol on macOS.
  [OWLApplication sharedApplication];

  owl::OWLMainDelegate delegate;
  content::ContentMainParams params(&delegate);
  params.argc = argc;
  params.argv = argv;
  return content::ContentMain(std::move(params));
}
