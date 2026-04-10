// Copyright 2026 AntlerAI. All rights reserved.
// Thin launcher for OWL Host .app bundle and Helper Apps.
// Uses dlopen to load OWL Host Framework and call OWLContentMain.
// Modeled after content/shell/app/shell_main_mac.cc.

#ifdef UNSAFE_BUFFERS_BUILD
// Thin launcher uses C-library calls (fprintf, strlen, snprintf, etc.) because
// it runs before the framework is loaded — base:: facilities are unavailable.
#pragma allow_unsafe_libc_calls
#endif

#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>

#include "base/allocator/early_zone_registration_apple.h"

#if defined(HELPER_EXECUTABLE)
#include "sandbox/mac/seatbelt_exec.h"  // nogncheck
#endif

namespace {

using ContentMainPtr = int (*)(int, const char**);

}  // namespace

int main(int argc, const char** argv) {
  partition_alloc::EarlyMallocZoneRegistration();

  // Get the executable's real path first — needed for seatbelt and dlopen.
  uint32_t exec_path_size = 0;
  int rv = _NSGetExecutablePath(NULL, &exec_path_size);
  if (rv != -1) {
    fprintf(stderr, "_NSGetExecutablePath: get length failed\n");
    abort();
  }

  std::unique_ptr<char[]> exec_path(new char[exec_path_size]);
  rv = _NSGetExecutablePath(exec_path.get(), &exec_path_size);
  if (rv != 0) {
    fprintf(stderr, "_NSGetExecutablePath: get path failed\n");
    abort();
  }

#if defined(HELPER_EXECUTABLE)
  // Initialize sandbox for helper processes if a seatbelt payload is present.
  // This mirrors content/shell/app/shell_main_mac.cc.
  // Note: OWL uses --no-sandbox in development; this code path activates
  // only when sandbox is properly configured for production.
  sandbox::SeatbeltExecServer::CreateFromArgumentsResult seatbelt =
      sandbox::SeatbeltExecServer::CreateFromArguments(exec_path.get(), argc,
                                                       argv);
  if (seatbelt.sandbox_required) {
    if (!seatbelt.server) {
      fprintf(stderr, "Failed to create seatbelt sandbox server.\n");
      abort();
    }
    if (!seatbelt.server->InitializeSandbox()) {
      fprintf(stderr, "Failed to initialize sandbox.\n");
      abort();
    }
  }

  // Helper is at:
  //   .../OWL Host Framework.framework/Versions/A/Helpers/
  //     OWL Host Helper.app/Contents/MacOS/OWL Host Helper
  // Go up 4 dirs from MacOS/ to Versions/A/, then append framework dylib name.
  const char rel_path[] = "../../../../" OWL_PRODUCT_NAME " Framework";
#else
  // Main app is at:
  //   OWL Host.app/Contents/MacOS/OWL Host
  // Go to Frameworks dir and load the framework dylib.
  const char rel_path[] =
      "../Frameworks/" OWL_PRODUCT_NAME " Framework.framework/"
      OWL_PRODUCT_NAME " Framework";
#endif

  const char* parent_dir = dirname(exec_path.get());
  if (!parent_dir) {
    fprintf(stderr, "dirname %s: %s\n", exec_path.get(), strerror(errno));
    abort();
  }

  const size_t parent_dir_len = strlen(parent_dir);
  const size_t rel_path_len = strlen(rel_path);
  const size_t framework_path_size = parent_dir_len + rel_path_len + 2;
  std::unique_ptr<char[]> framework_path(new char[framework_path_size]);
  snprintf(framework_path.get(), framework_path_size, "%s/%s", parent_dir,
           rel_path);

  void* library =
      dlopen(framework_path.get(), RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!library) {
    fprintf(stderr, "dlopen %s: %s\n", framework_path.get(), dlerror());
    abort();
  }

  const ContentMainPtr content_main =
      reinterpret_cast<ContentMainPtr>(dlsym(library, "OWLContentMain"));
  if (!content_main) {
    fprintf(stderr, "dlsym OWLContentMain: %s\n", dlerror());
    abort();
  }

  rv = content_main(argc, argv);
  exit(rv);
}
