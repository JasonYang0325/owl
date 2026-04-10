// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/bridge/owl_bridge_api.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// --- OWLBridge_SetPermissionRequestCallback ---

// AC-1: Registering a permission request callback does not crash.
TEST(OWLBridgePermissionTest, SetCallbackDoesNotCrash) {
  auto callback = [](const char* origin, int permission_type,
                     uint64_t request_id, void* context) {};
  OWLBridge_SetPermissionRequestCallback(callback, nullptr);
  // Unregister by passing NULL.
  OWLBridge_SetPermissionRequestCallback(nullptr, nullptr);
}

// AC-1b: Setting callback with non-null context does not crash.
TEST(OWLBridgePermissionTest, SetCallbackWithContextDoesNotCrash) {
  int dummy_context = 42;
  auto callback = [](const char* origin, int permission_type,
                     uint64_t request_id, void* context) {};
  OWLBridge_SetPermissionRequestCallback(callback, &dummy_context);
  OWLBridge_SetPermissionRequestCallback(nullptr, nullptr);
}

// --- OWLBridge_RespondToPermission ---

// AC-2: RespondToPermission with arbitrary request_id when Bridge is not
// initialized does not crash (silently ignored per API contract).
TEST(OWLBridgePermissionTest, RespondUninitializedDoesNotCrash) {
  // status 0 = Granted
  OWLBridge_RespondToPermission(/*request_id=*/999, /*status=*/0);
}

// AC-2b: RespondToPermission with Denied status does not crash.
TEST(OWLBridgePermissionTest, RespondDeniedUninitializedDoesNotCrash) {
  // status 1 = Denied
  OWLBridge_RespondToPermission(/*request_id=*/0, /*status=*/1);
}

// --- OWLBridge_PermissionGetAll ---

// AC-3: PermissionGetAll when Bridge is not initialized does not crash
// (callback may fire synchronously with NULL/error, or be silently ignored).
TEST(OWLBridgePermissionTest, GetAllUninitializedDoesNotCrash) {
  auto callback = [](const char* json_array, const char* error_msg,
                     void* context) {};
  OWLBridge_PermissionGetAll(callback, nullptr);
}

// --- OWLBridge_PermissionReset ---

// AC-4: PermissionReset when Bridge is not initialized does not crash
// (fire-and-forget, silently returns).
TEST(OWLBridgePermissionTest, ResetUninitializedDoesNotCrash) {
  // permission_type 0 = Camera
  OWLBridge_PermissionReset("https://example.com", /*permission_type=*/0);
}

// AC-4b: PermissionReset with NULL origin does not crash.
TEST(OWLBridgePermissionTest, ResetNullOriginDoesNotCrash) {
  OWLBridge_PermissionReset(nullptr, /*permission_type=*/1);
}

// AC-4c: PermissionResetAll when Bridge is not initialized does not crash.
TEST(OWLBridgePermissionTest, ResetAllUninitializedDoesNotCrash) {
  OWLBridge_PermissionResetAll();
}

// --- OWLBridge_PermissionGet ---

// AC-3b: PermissionGet (single query) when Bridge is not initialized does
// not crash.
TEST(OWLBridgePermissionTest, GetSingleUninitializedDoesNotCrash) {
  auto callback = [](int status, const char* error_msg, void* context) {};
  OWLBridge_PermissionGet("https://example.com", /*permission_type=*/2,
                          callback, nullptr);
}

// --- OWLBridge_RespondToPermission edge cases ---

// AC-2c: RespondToPermission with Ask status (2) does not crash.
TEST(OWLBridgePermissionTest, RespondAskStatusDoesNotCrash) {
  OWLBridge_RespondToPermission(/*request_id=*/42, /*status=*/2);
}

// AC-2d: RespondToPermission with UINT64_MAX request_id does not crash.
TEST(OWLBridgePermissionTest, RespondMaxRequestIdDoesNotCrash) {
  OWLBridge_RespondToPermission(/*request_id=*/UINT64_MAX, /*status=*/0);
}

// AC-2e: RespondToPermission with out-of-range status does not crash.
TEST(OWLBridgePermissionTest, RespondInvalidStatusDoesNotCrash) {
  OWLBridge_RespondToPermission(/*request_id=*/1, /*status=*/99);
}

// --- OWLBridge_PermissionGet edge cases ---

// AC-3c: PermissionGet with NULL origin does not crash.
TEST(OWLBridgePermissionTest, GetNullOriginDoesNotCrash) {
  auto callback = [](int status, const char* error_msg, void* context) {};
  OWLBridge_PermissionGet(nullptr, /*permission_type=*/0, callback, nullptr);
}

// AC-3d: PermissionGet with out-of-range permission_type does not crash.
TEST(OWLBridgePermissionTest, GetInvalidTypeDoesNotCrash) {
  auto callback = [](int status, const char* error_msg, void* context) {};
  OWLBridge_PermissionGet("https://example.com", /*permission_type=*/99,
                          callback, nullptr);
}

// AC-3e: PermissionGet with NULL callback does not crash.
TEST(OWLBridgePermissionTest, GetNullCallbackDoesNotCrash) {
  OWLBridge_PermissionGet("https://example.com", /*permission_type=*/0,
                          nullptr, nullptr);
}

// --- OWLBridge_PermissionGetAll edge cases ---

// AC-3f: PermissionGetAll with NULL callback does not crash.
TEST(OWLBridgePermissionTest, GetAllNullCallbackDoesNotCrash) {
  OWLBridge_PermissionGetAll(nullptr, nullptr);
}

// --- OWLBridge_PermissionReset edge cases ---

// AC-4d: PermissionReset with out-of-range permission_type does not crash.
TEST(OWLBridgePermissionTest, ResetInvalidTypeDoesNotCrash) {
  OWLBridge_PermissionReset("https://example.com", /*permission_type=*/99);
}

// AC-4e: PermissionReset with empty-string origin does not crash.
TEST(OWLBridgePermissionTest, ResetEmptyOriginDoesNotCrash) {
  OWLBridge_PermissionReset("", /*permission_type=*/0);
}

// --- OWLBridge_SetPermissionRequestCallback edge cases ---

// AC-1c: Replacing an existing callback without clearing first does not crash.
TEST(OWLBridgePermissionTest, ReplaceCallbackDoesNotCrash) {
  auto callback1 = [](const char* origin, int permission_type,
                      uint64_t request_id, void* context) {};
  auto callback2 = [](const char* origin, int permission_type,
                      uint64_t request_id, void* context) {};
  OWLBridge_SetPermissionRequestCallback(callback1, nullptr);
  // Directly replace without clearing.
  OWLBridge_SetPermissionRequestCallback(callback2, nullptr);
  // Clean up.
  OWLBridge_SetPermissionRequestCallback(nullptr, nullptr);
}

}  // namespace
}  // namespace owl
