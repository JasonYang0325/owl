// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// C-ABI integration tests for download functions declared in owl_bridge_api.h.
// Tests verify that each C-ABI function can be called safely when the bridge
// is not fully initialized (no active session), validating signatures and
// crash-safety. Follows the same pattern as owl_bridge_permission_unittest.mm.

#include "third_party/owl/bridge/owl_bridge_api.h"

#include <cstdint>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// =============================================================================
// OWLBridge_DownloadGetAll — C-ABI crash-safety tests
// =============================================================================

// AC-DL-1: DownloadGetAll with valid callback does not crash when uninitialized.
TEST(OWLBridgeDownloadTest, GetAll_UninitializedDoesNotCrash) {
  auto callback = [](const char* json_array, const char* error_msg,
                     void* context) {};
  OWLBridge_DownloadGetAll(callback, nullptr);
}

// AC-DL-1b: DownloadGetAll with non-null context does not crash.
TEST(OWLBridgeDownloadTest, GetAll_WithContextDoesNotCrash) {
  int dummy_context = 42;
  auto callback = [](const char* json_array, const char* error_msg,
                     void* context) {};
  OWLBridge_DownloadGetAll(callback, &dummy_context);
}

// AC-DL-1c: DownloadGetAll with NULL callback does not crash.
TEST(OWLBridgeDownloadTest, GetAll_NullCallbackDoesNotCrash) {
  OWLBridge_DownloadGetAll(nullptr, nullptr);
}

// =============================================================================
// OWLBridge_SetDownloadCallback — C-ABI crash-safety tests
// =============================================================================

// AC-DL-2: Registering a download event callback does not crash.
TEST(OWLBridgeDownloadTest, SetCallback_DoesNotCrash) {
  auto callback = [](const char* json_item, int32_t event_type,
                     void* context) {};
  OWLBridge_SetDownloadCallback(callback, nullptr);
  // Unregister by passing NULL.
  OWLBridge_SetDownloadCallback(nullptr, nullptr);
}

// AC-DL-2b: Setting callback with non-null context does not crash.
TEST(OWLBridgeDownloadTest, SetCallback_WithContextDoesNotCrash) {
  int dummy_context = 99;
  auto callback = [](const char* json_item, int32_t event_type,
                     void* context) {};
  OWLBridge_SetDownloadCallback(callback, &dummy_context);
  OWLBridge_SetDownloadCallback(nullptr, nullptr);
}

// AC-DL-2c: Replacing an existing callback without clearing first does not crash.
TEST(OWLBridgeDownloadTest, SetCallback_ReplaceDoesNotCrash) {
  auto callback1 = [](const char* json_item, int32_t event_type,
                      void* context) {};
  auto callback2 = [](const char* json_item, int32_t event_type,
                      void* context) {};
  OWLBridge_SetDownloadCallback(callback1, nullptr);
  // Directly replace without clearing.
  OWLBridge_SetDownloadCallback(callback2, nullptr);
  // Clean up.
  OWLBridge_SetDownloadCallback(nullptr, nullptr);
}

// =============================================================================
// OWLBridge_DownloadPause — C-ABI crash-safety tests
// =============================================================================

// AC-DL-3: Pause with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadTest, Pause_UninitializedDoesNotCrash) {
  OWLBridge_DownloadPause(/*download_id=*/1);
}

// AC-DL-3b: Pause with ID 0 does not crash.
TEST(OWLBridgeDownloadTest, Pause_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadPause(/*download_id=*/0);
}

// AC-DL-3c: Pause with UINT32_MAX ID does not crash.
TEST(OWLBridgeDownloadTest, Pause_MaxIdDoesNotCrash) {
  OWLBridge_DownloadPause(/*download_id=*/UINT32_MAX);
}

// =============================================================================
// OWLBridge_DownloadResume — C-ABI crash-safety tests
// =============================================================================

// AC-DL-4: Resume with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadTest, Resume_UninitializedDoesNotCrash) {
  OWLBridge_DownloadResume(/*download_id=*/1);
}

// AC-DL-4b: Resume with ID 0 does not crash.
TEST(OWLBridgeDownloadTest, Resume_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadResume(/*download_id=*/0);
}

// AC-DL-4c: Resume with UINT32_MAX ID does not crash.
TEST(OWLBridgeDownloadTest, Resume_MaxIdDoesNotCrash) {
  OWLBridge_DownloadResume(/*download_id=*/UINT32_MAX);
}

// =============================================================================
// OWLBridge_DownloadCancel — C-ABI crash-safety tests
// =============================================================================

// AC-DL-5: Cancel with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadTest, Cancel_UninitializedDoesNotCrash) {
  OWLBridge_DownloadCancel(/*download_id=*/1);
}

// AC-DL-5b: Cancel with ID 0 does not crash.
TEST(OWLBridgeDownloadTest, Cancel_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadCancel(/*download_id=*/0);
}

// =============================================================================
// OWLBridge_DownloadRemoveEntry — C-ABI crash-safety tests
// =============================================================================

// AC-DL-6: RemoveEntry with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadTest, RemoveEntry_UninitializedDoesNotCrash) {
  OWLBridge_DownloadRemoveEntry(/*download_id=*/1);
}

// AC-DL-6b: RemoveEntry with ID 0 does not crash.
TEST(OWLBridgeDownloadTest, RemoveEntry_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadRemoveEntry(/*download_id=*/0);
}

// AC-DL-6c: RemoveEntry with UINT32_MAX ID does not crash.
TEST(OWLBridgeDownloadTest, RemoveEntry_MaxIdDoesNotCrash) {
  OWLBridge_DownloadRemoveEntry(/*download_id=*/UINT32_MAX);
}

// =============================================================================
// OWLBridge_DownloadOpenFile — C-ABI crash-safety tests
// =============================================================================

// AC-DL-7: OpenFile with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadTest, OpenFile_UninitializedDoesNotCrash) {
  OWLBridge_DownloadOpenFile(/*download_id=*/1);
}

// AC-DL-7b: OpenFile with ID 0 does not crash.
TEST(OWLBridgeDownloadTest, OpenFile_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadOpenFile(/*download_id=*/0);
}

// =============================================================================
// OWLBridge_DownloadShowInFolder — C-ABI crash-safety tests
// =============================================================================

// AC-DL-8: ShowInFolder with arbitrary ID when uninitialized does not crash.
TEST(OWLBridgeDownloadTest, ShowInFolder_UninitializedDoesNotCrash) {
  OWLBridge_DownloadShowInFolder(/*download_id=*/1);
}

// AC-DL-8b: ShowInFolder with ID 0 does not crash.
TEST(OWLBridgeDownloadTest, ShowInFolder_ZeroIdDoesNotCrash) {
  OWLBridge_DownloadShowInFolder(/*download_id=*/0);
}

// =============================================================================
// Callback type signature compile-time validation
// =============================================================================

// AC-DL-9: Verify OWLBridge_DownloadListCallback signature compiles correctly.
// This is a compile-time test: if the callback type changes incompatibly,
// this test will fail to compile.
TEST(OWLBridgeDownloadTest, ListCallbackSignature_Compiles) {
  OWLBridge_DownloadListCallback cb =
      [](const char* json_array, const char* error_msg, void* context) {};
  EXPECT_NE(cb, nullptr);
}

// AC-DL-10: Verify OWLBridge_DownloadEventCallback signature compiles correctly.
TEST(OWLBridgeDownloadTest, EventCallbackSignature_Compiles) {
  OWLBridge_DownloadEventCallback cb =
      [](const char* json_item, int32_t event_type, void* context) {};
  EXPECT_NE(cb, nullptr);
}

// AC-DL-11: Verify event_type constants are usable with the callback typedef.
// event_type: 0=created, 1=updated, 2=removed
TEST(OWLBridgeDownloadTest, EventTypeConstants_AreValid) {
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
