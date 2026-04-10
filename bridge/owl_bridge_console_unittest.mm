// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// C-ABI integration tests for Console Phase 2 callback
// declared in owl_bridge_api.h.
//
// Tests verify that OWLBridge_SetConsoleMessageCallback can be called safely
// when the bridge is not fully initialized (no active session), validating
// signatures and crash-safety. Follows the same pattern as
// owl_bridge_navigation_unittest.mm.

#include "third_party/owl/bridge/owl_bridge_api.h"

#include <cstdint>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// =============================================================================
// OWLBridge_SetConsoleMessageCallback — C-ABI crash-safety tests
// =============================================================================

// AC-CON-1: Registering a console message callback does not crash
// when the bridge has no active webview (g_webview is empty).
TEST(OWLBridgeConsoleTest, SetCallback_UninitializedDoesNotCrash) {
  auto callback = [](int level, const char* message, const char* source,
                     int line, double timestamp, void* ctx) {};
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, callback, nullptr);
}

// AC-CON-1b: Setting console callback with non-null context does not crash.
TEST(OWLBridgeConsoleTest, SetCallback_WithContextDoesNotCrash) {
  int dummy_context = 42;
  auto callback = [](int level, const char* message, const char* source,
                     int line, double timestamp, void* ctx) {};
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, callback,
                                      &dummy_context);
}

// AC-CON-1c: Unregistering console callback (NULL) does not crash.
TEST(OWLBridgeConsoleTest, SetCallback_NullDoesNotCrash) {
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-CON-1d: Replacing an existing console callback without clearing first
// does not crash.
TEST(OWLBridgeConsoleTest, SetCallback_ReplaceDoesNotCrash) {
  auto cb1 = [](int level, const char* message, const char* source,
                int line, double timestamp, void* ctx) {};
  auto cb2 = [](int level, const char* message, const char* source,
                int line, double timestamp, void* ctx) {};
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, cb1, nullptr);
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, cb2, nullptr);
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-CON-2: Register-unregister cycle repeated does not leak or crash.
TEST(OWLBridgeConsoleTest, SetCallback_RepeatedCycleDoesNotCrash) {
  for (int i = 0; i < 10; ++i) {
    auto callback = [](int level, const char* message, const char* source,
                       int line, double timestamp, void* ctx) {};
    OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, callback, nullptr);
    OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, nullptr, nullptr);
  }
}

// AC-CON-3: Console callback can coexist with navigation callbacks.
TEST(OWLBridgeConsoleTest, CoexistsWithNavigationCallbacks) {
  auto console_cb = [](int level, const char* message, const char* source,
                       int line, double timestamp, void* ctx) {};
  auto nav_started_cb = [](int64_t nav_id, const char* url,
                           int is_user_initiated, int is_redirect,
                           void* ctx) {};

  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, console_cb, nullptr);
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, nav_started_cb,
                                         nullptr);

  // Unregister all.
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, nullptr, nullptr);
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-CON-4: Different webview_ids can each have their own console callback.
TEST(OWLBridgeConsoleTest, DifferentWebviewIds_DoNotCrash) {
  auto cb1 = [](int level, const char* message, const char* source,
                int line, double timestamp, void* ctx) {};
  auto cb2 = [](int level, const char* message, const char* source,
                int line, double timestamp, void* ctx) {};

  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, cb1, nullptr);
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/2, cb2, nullptr);

  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/1, nullptr, nullptr);
  OWLBridge_SetConsoleMessageCallback(/*webview_id=*/2, nullptr, nullptr);
}

}  // namespace
}  // namespace owl
