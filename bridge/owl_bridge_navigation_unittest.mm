// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// C-ABI integration tests for Phase 2 navigation lifecycle callbacks
// declared in owl_bridge_api.h.
//
// Tests verify that each C-ABI function can be called safely when the bridge
// is not fully initialized (no active session), validating signatures and
// crash-safety. Follows the same pattern as owl_bridge_download_unittest.mm.

#include "third_party/owl/bridge/owl_bridge_api.h"

#include <cstdint>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// =============================================================================
// OWLBridge_SetNavigationStartedCallback — C-ABI crash-safety tests
// =============================================================================

// AC-NAV-1: Registering a navigation started callback does not crash
// when the bridge has no active webview (g_webview is empty).
TEST(OWLBridgeNavigationTest, SetStartedCallback_UninitializedDoesNotCrash) {
  auto callback = [](int64_t nav_id, const char* url,
                     int is_user_initiated, int is_redirect, void* ctx) {};
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, callback, nullptr);
}

// AC-NAV-1b: Setting navigation started callback with context does not crash.
TEST(OWLBridgeNavigationTest, SetStartedCallback_WithContextDoesNotCrash) {
  int dummy_context = 42;
  auto callback = [](int64_t nav_id, const char* url,
                     int is_user_initiated, int is_redirect, void* ctx) {};
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, callback,
                                         &dummy_context);
}

// AC-NAV-1c: Unregistering navigation started callback (NULL) does not crash.
TEST(OWLBridgeNavigationTest, SetStartedCallback_NullDoesNotCrash) {
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-NAV-1d: Replacing an existing started callback without clearing first
// does not crash.
TEST(OWLBridgeNavigationTest, SetStartedCallback_ReplaceDoesNotCrash) {
  auto cb1 = [](int64_t nav_id, const char* url,
                int is_user_initiated, int is_redirect, void* ctx) {};
  auto cb2 = [](int64_t nav_id, const char* url,
                int is_user_initiated, int is_redirect, void* ctx) {};
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, cb1, nullptr);
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, cb2, nullptr);
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, nullptr, nullptr);
}

// =============================================================================
// OWLBridge_SetNavigationCommittedCallback — C-ABI crash-safety tests
// =============================================================================

// AC-NAV-2: Registering a navigation committed callback does not crash
// when the bridge has no active webview.
TEST(OWLBridgeNavigationTest, SetCommittedCallback_UninitializedDoesNotCrash) {
  auto callback = [](int64_t nav_id, const char* url,
                     int http_status, void* ctx) {};
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, callback, nullptr);
}

// AC-NAV-2b: Setting committed callback with non-null context does not crash.
TEST(OWLBridgeNavigationTest, SetCommittedCallback_WithContextDoesNotCrash) {
  int dummy_context = 99;
  auto callback = [](int64_t nav_id, const char* url,
                     int http_status, void* ctx) {};
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, callback,
                                           &dummy_context);
}

// AC-NAV-2c: Unregistering committed callback (NULL) does not crash.
TEST(OWLBridgeNavigationTest, SetCommittedCallback_NullDoesNotCrash) {
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-NAV-2d: Replacing an existing committed callback does not crash.
TEST(OWLBridgeNavigationTest, SetCommittedCallback_ReplaceDoesNotCrash) {
  auto cb1 = [](int64_t nav_id, const char* url,
                int http_status, void* ctx) {};
  auto cb2 = [](int64_t nav_id, const char* url,
                int http_status, void* ctx) {};
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, cb1, nullptr);
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, cb2, nullptr);
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, nullptr, nullptr);
}

// =============================================================================
// OWLBridge_SetNavigationErrorCallback — C-ABI crash-safety tests
// =============================================================================

// AC-NAV-3: Registering a navigation error callback does not crash
// when the bridge has no active webview.
TEST(OWLBridgeNavigationTest, SetErrorCallback_UninitializedDoesNotCrash) {
  auto callback = [](int64_t nav_id, const char* url,
                     int error_code, const char* error_desc, void* ctx) {};
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, callback, nullptr);
}

// AC-NAV-3b: Setting error callback with context does not crash.
TEST(OWLBridgeNavigationTest, SetErrorCallback_WithContextDoesNotCrash) {
  int dummy_context = 7;
  auto callback = [](int64_t nav_id, const char* url,
                     int error_code, const char* error_desc, void* ctx) {};
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, callback,
                                       &dummy_context);
}

// AC-NAV-3c: Unregistering error callback (NULL) does not crash.
TEST(OWLBridgeNavigationTest, SetErrorCallback_NullDoesNotCrash) {
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-NAV-3d: Replacing an existing error callback does not crash.
TEST(OWLBridgeNavigationTest, SetErrorCallback_ReplaceDoesNotCrash) {
  auto cb1 = [](int64_t nav_id, const char* url,
                int error_code, const char* error_desc, void* ctx) {};
  auto cb2 = [](int64_t nav_id, const char* url,
                int error_code, const char* error_desc, void* ctx) {};
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, cb1, nullptr);
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, cb2, nullptr);
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, nullptr, nullptr);
}

// =============================================================================
// Cross-callback — verify all three can coexist without interference
// =============================================================================

// AC-NAV-4: Registering all three callbacks simultaneously does not crash.
TEST(OWLBridgeNavigationTest, AllThreeCallbacks_CoexistSafely) {
  auto started_cb = [](int64_t nav_id, const char* url,
                       int is_user_initiated, int is_redirect, void* ctx) {};
  auto committed_cb = [](int64_t nav_id, const char* url,
                         int http_status, void* ctx) {};
  auto error_cb = [](int64_t nav_id, const char* url,
                     int error_code, const char* error_desc, void* ctx) {};

  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, started_cb, nullptr);
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, committed_cb,
                                           nullptr);
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, error_cb, nullptr);

  // Unregister all.
  OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, nullptr, nullptr);
  OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, nullptr, nullptr);
  OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-NAV-4b: Register-unregister cycle repeated does not leak or crash.
TEST(OWLBridgeNavigationTest, AllThreeCallbacks_RepeatedCycleDoesNotCrash) {
  for (int i = 0; i < 10; ++i) {
    auto started_cb = [](int64_t nav_id, const char* url,
                         int is_user_initiated, int is_redirect, void* ctx) {};
    auto committed_cb = [](int64_t nav_id, const char* url,
                           int http_status, void* ctx) {};
    auto error_cb = [](int64_t nav_id, const char* url,
                       int error_code, const char* error_desc, void* ctx) {};

    OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, started_cb,
                                           nullptr);
    OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, committed_cb,
                                             nullptr);
    OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, error_cb, nullptr);

    OWLBridge_SetNavigationStartedCallback(/*webview_id=*/1, nullptr, nullptr);
    OWLBridge_SetNavigationCommittedCallback(/*webview_id=*/1, nullptr, nullptr);
    OWLBridge_SetNavigationErrorCallback(/*webview_id=*/1, nullptr, nullptr);
  }
}

}  // namespace
}  // namespace owl
