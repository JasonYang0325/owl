// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// C-ABI integration tests for download functions declared in owl_bridge_api.h.
// Tests verify that each C-ABI function can be called safely when the bridge
// is not fully initialized (no active session), validating function signatures
// and crash-safety across the bridge boundary.
//
// These tests complement the host-side OWLDownloadService tests by verifying
// the C-ABI layer that Swift calls through.

#include "third_party/owl/bridge/owl_bridge_api.h"

#include <cstdint>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// =============================================================================
// OWLBridge_DownloadGetAll — C-ABI crash-safety tests
// =============================================================================

// DownloadGetAll with valid callback does not crash when uninitialized.
TEST(OWLBridgeDownloadCABITest, GetAll_UninitializedDoesNotCrash) {
  auto callback = [](const char* json_array, const char* error_msg,
                     void* context) {};
  OWLBridge_DownloadGetAll(callback, nullptr);
}

// DownloadGetAll with non-null context does not crash.
TEST(OWLBridgeDownloadCABITest, GetAll_WithContextDoesNotCrash) {
  int dummy_context = 42;
  auto callback = [](const char* json_array, const char* error_msg,
                     void* context) {};
  OWLBridge_DownloadGetAll(callback, &dummy_context);
}

// DownloadGetAll with NULL callback does not crash.
TEST(OWLBridgeDownloadCABITest, GetAll_NullCallbackDoesNotCrash) {
  OWLBridge_DownloadGetAll(nullptr, nullptr);
}

// =============================================================================
// OWLBridge_SetDownloadCallback — C-ABI crash-safety tests
// =============================================================================

// Registering a download event callback does not crash.
TEST(OWLBridgeDownloadCABITest, SetCallback_DoesNotCrash) {
  auto callback = [](const char* json_item, int32_t event_type,
                     void* context) {};
  OWLBridge_SetDownloadCallback(callback, nullptr);
  // Unregister by passing NULL.
  OWLBridge_SetDownloadCallback(nullptr, nullptr);
}

// Setting callback with non-null context does not crash.
TEST(OWLBridgeDownloadCABITest, SetCallback_WithContextDoesNotCrash) {
  int dummy_context = 99;
  auto callback = [](const char* json_item, int32_t event_type,
                     void* context) {};
  OWLBridge_SetDownloadCallback(callback, &dummy_context);
  OWLBridge_SetDownloadCallback(nullptr, nullptr);
}

// Replacing an existing callback without clearing first does not crash.
TEST(OWLBridgeDownloadCABITest, SetCallback_ReplaceDoesNotCrash) {
  auto callback1 = [](const char* json_item, int32_t event_type,
                      void* context) {};
  auto callback2 = [](const char* json_item, int32_t event_type,
                      void* context) {};
  OWLBridge_SetDownloadCallback(callback1, nullptr);
  OWLBridge_SetDownloadCallback(callback2, nullptr);
  OWLBridge_SetDownloadCallback(nullptr, nullptr);
}

// =============================================================================
// OWLBridge_DownloadPause — C-ABI crash-safety tests
// =============================================================================

// Pause with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadCABITest, Pause_UninitializedDoesNotCrash) {
  OWLBridge_DownloadPause(/*download_id=*/1);
}

// Pause with ID 0 does not crash.
TEST(OWLBridgeDownloadCABITest, Pause_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadPause(/*download_id=*/0);
}

// Pause with UINT32_MAX ID does not crash.
TEST(OWLBridgeDownloadCABITest, Pause_MaxIdDoesNotCrash) {
  OWLBridge_DownloadPause(/*download_id=*/UINT32_MAX);
}

// =============================================================================
// OWLBridge_DownloadResume — C-ABI crash-safety tests
// =============================================================================

// Resume with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadCABITest, Resume_UninitializedDoesNotCrash) {
  OWLBridge_DownloadResume(/*download_id=*/1);
}

// Resume with ID 0 does not crash.
TEST(OWLBridgeDownloadCABITest, Resume_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadResume(/*download_id=*/0);
}

// Resume with UINT32_MAX ID does not crash.
TEST(OWLBridgeDownloadCABITest, Resume_MaxIdDoesNotCrash) {
  OWLBridge_DownloadResume(/*download_id=*/UINT32_MAX);
}

// =============================================================================
// OWLBridge_DownloadCancel — C-ABI crash-safety tests
// =============================================================================

// Cancel with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadCABITest, Cancel_UninitializedDoesNotCrash) {
  OWLBridge_DownloadCancel(/*download_id=*/1);
}

// Cancel with ID 0 does not crash.
TEST(OWLBridgeDownloadCABITest, Cancel_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadCancel(/*download_id=*/0);
}

// =============================================================================
// OWLBridge_DownloadRemoveEntry — C-ABI crash-safety tests
// =============================================================================

// RemoveEntry with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadCABITest, RemoveEntry_UninitializedDoesNotCrash) {
  OWLBridge_DownloadRemoveEntry(/*download_id=*/1);
}

// RemoveEntry with ID 0 does not crash.
TEST(OWLBridgeDownloadCABITest, RemoveEntry_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadRemoveEntry(/*download_id=*/0);
}

// RemoveEntry with UINT32_MAX ID does not crash.
TEST(OWLBridgeDownloadCABITest, RemoveEntry_MaxIdDoesNotCrash) {
  OWLBridge_DownloadRemoveEntry(/*download_id=*/UINT32_MAX);
}

// =============================================================================
// OWLBridge_DownloadOpenFile — C-ABI crash-safety tests
// =============================================================================

// OpenFile with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadCABITest, OpenFile_UninitializedDoesNotCrash) {
  OWLBridge_DownloadOpenFile(/*download_id=*/1);
}

// OpenFile with ID 0 does not crash.
TEST(OWLBridgeDownloadCABITest, OpenFile_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadOpenFile(/*download_id=*/0);
}

// =============================================================================
// OWLBridge_DownloadShowInFolder — C-ABI crash-safety tests
// =============================================================================

// ShowInFolder with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadCABITest, ShowInFolder_UninitializedDoesNotCrash) {
  OWLBridge_DownloadShowInFolder(/*download_id=*/1);
}

// ShowInFolder with ID 0 does not crash.
TEST(OWLBridgeDownloadCABITest, ShowInFolder_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadShowInFolder(/*download_id=*/0);
}

// =============================================================================
// Callback type signature compile-time validation
// =============================================================================

// Verify OWLBridge_DownloadListCallback signature compiles correctly.
// If the callback type changes incompatibly, this test fails to compile.
TEST(OWLBridgeDownloadCABITest, ListCallbackSignature_Compiles) {
  OWLBridge_DownloadListCallback cb =
      [](const char* json_array, const char* error_msg, void* context) {};
  EXPECT_NE(cb, nullptr);
}

// Verify OWLBridge_DownloadEventCallback signature compiles correctly.
TEST(OWLBridgeDownloadCABITest, EventCallbackSignature_Compiles) {
  OWLBridge_DownloadEventCallback cb =
      [](const char* json_item, int32_t event_type, void* context) {};
  EXPECT_NE(cb, nullptr);
}

// Verify event_type constants are usable with the callback typedef.
// event_type: 0=created, 1=updated, 2=removed
TEST(OWLBridgeDownloadCABITest, EventTypeConstants_AreValid) {
  constexpr int32_t kCreated = 0;
  constexpr int32_t kUpdated = 1;
  constexpr int32_t kRemoved = 2;

  int32_t captured_type = -1;
  OWLBridge_DownloadEventCallback cb =
      [](const char* json_item, int32_t event_type, void* context) {
        *static_cast<int32_t*>(context) = event_type;
      };

  // Simulate each event_type through the callback.
  cb(R"({"id":1})", kCreated, &captured_type);
  EXPECT_EQ(captured_type, 0);

  cb(R"({"id":1})", kUpdated, &captured_type);
  EXPECT_EQ(captured_type, 1);

  cb(R"({"id":1})", kRemoved, &captured_type);
  EXPECT_EQ(captured_type, 2);
}

}  // namespace
}  // namespace owl
