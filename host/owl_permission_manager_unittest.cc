// Copyright 2026 AntlerAI. All rights reserved.
// Unit tests for OWLPermissionManager.
// Tests are organized by AC (Acceptance Criteria) from
// phase-1-host-permission-manager.md.

#include "third_party/owl/host/owl_permission_manager.h"

#include <string>

#include "base/files/file_util.h"
#include "third_party/owl/host/owl_content_browser_context.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/test/task_environment.h"
#include "content/public/browser/permission_descriptor_util.h"
#include "content/public/browser/permission_request_description.h"
#include "content/public/browser/permission_result.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/blink/public/common/permissions/permission_utils.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace owl {
namespace {

// Aliases for readability.
using PermissionStatus = content::PermissionStatus;
using PermissionType = blink::PermissionType;

const char kOriginA[] = "https://example.com";
const char kOriginB[] = "https://other.com";
const char kOriginMeet[] = "https://meet.google.com";

url::Origin MakeOrigin(const char* url_str) {
  return url::Origin::Create(GURL(url_str));
}

// =============================================================================
// Test fixture: file-backed mode (uses ScopedTempDir)
// =============================================================================

class OWLPermissionManagerTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    permissions_path_ =
        temp_dir_.GetPath().AppendASCII("permissions.json");
    manager_ = std::make_unique<OWLPermissionManager>(permissions_path_);
  }

  // Recreate manager from the same file path (simulates restart).
  void ReloadManager() {
    manager_.reset();
    manager_ = std::make_unique<OWLPermissionManager>(permissions_path_);
  }

  // Write raw content to the permissions file.
  void WriteRawFile(const std::string& content) {
    ASSERT_TRUE(base::WriteFile(permissions_path_, content));
  }

  // Read raw content from the permissions file.
  std::string ReadRawFile() {
    std::string content;
    base::ReadFileToString(permissions_path_, &content);
    return content;
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  base::ScopedTempDir temp_dir_;
  base::FilePath permissions_path_;
  std::unique_ptr<OWLPermissionManager> manager_;
};

// =============================================================================
// AC-P1-1: Query permission status (default returns ASK)
// =============================================================================

// AC-P1-1: Happy path — unset permission returns ASK.
TEST_F(OWLPermissionManagerTest, DefaultReturnsAsk) {
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// AC-P1-1: All four supported types default to ASK.
TEST_F(OWLPermissionManagerTest, AllSupportedTypesDefaultToAsk) {
  auto origin = MakeOrigin(kOriginA);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::AUDIO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::GEOLOCATION),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::NOTIFICATIONS),
            PermissionStatus::ASK);
}

// AC-P1-1: Unsupported permission type also defaults to ASK.
TEST_F(OWLPermissionManagerTest, UnsupportedTypeDefaultsToAsk) {
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::MIDI_SYSEX),
            PermissionStatus::ASK);
}

// AC-P1-1: Fresh manager has zero stored permission entries.
TEST_F(OWLPermissionManagerTest, InitialPermissionCountIsZero) {
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-1: GetAllPermissions is empty on a fresh manager.
TEST_F(OWLPermissionManagerTest, GetAllPermissionsInitiallyEmpty) {
  auto all = manager_->GetAllPermissions();
  EXPECT_TRUE(all.empty());
}

// =============================================================================
// AC-P1-2: SetPermission then GetPermission returns new status
// =============================================================================

// AC-P1-2: Happy path — set GRANTED, read back GRANTED.
TEST_F(OWLPermissionManagerTest, SetPermissionGranted) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
}

// AC-P1-2: Set DENIED, read back DENIED.
TEST_F(OWLPermissionManagerTest, SetPermissionDenied) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::AUDIO_CAPTURE),
            PermissionStatus::DENIED);
}

// AC-P1-2: Overwrite DENIED with GRANTED.
TEST_F(OWLPermissionManagerTest, OverwritePermission) {
  auto origin = MakeOrigin(kOriginA);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::DENIED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::DENIED);

  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
}

// AC-P1-2: Setting ASK removes the entry (ASK is the default, not stored).
TEST_F(OWLPermissionManagerTest, SetAskRemovesEntry) {
  auto origin = MakeOrigin(kOriginA);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->permission_count_for_testing(), 1u);

  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-2: Different origins are fully isolated.
TEST_F(OWLPermissionManagerTest, DifferentOriginsIsolated) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  // Origin B should still be ASK.
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginB),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  // Origin A is GRANTED.
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
}

// AC-P1-2: Different permission types within the same origin are isolated.
TEST_F(OWLPermissionManagerTest, DifferentPermissionTypesIsolated) {
  auto origin = MakeOrigin(kOriginA);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(origin, PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);

  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::AUDIO_CAPTURE),
            PermissionStatus::DENIED);
  // Geolocation was not set — should be ASK.
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::GEOLOCATION),
            PermissionStatus::ASK);
}

// AC-P1-2: Multiple permission types per origin all stored correctly.
TEST_F(OWLPermissionManagerTest, MultiplePermissionsPerOrigin) {
  auto origin = MakeOrigin(kOriginMeet);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(origin, PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(origin, PermissionType::GEOLOCATION,
                          PermissionStatus::DENIED);
  manager_->SetPermission(origin, PermissionType::NOTIFICATIONS,
                          PermissionStatus::DENIED);

  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::AUDIO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::GEOLOCATION),
            PermissionStatus::DENIED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::NOTIFICATIONS),
            PermissionStatus::DENIED);
}

// AC-P1-2: GetAllPermissions returns all set entries.
TEST_F(OWLPermissionManagerTest, GetAllPermissionsReturnsAll) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginB),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);

  auto all = manager_->GetAllPermissions();
  EXPECT_EQ(all.size(), 2u);
}

// AC-P1-2: GetAllPermissions returns correct tuples.
TEST_F(OWLPermissionManagerTest, GetAllPermissionsContainsCorrectData) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);

  auto all = manager_->GetAllPermissions();
  ASSERT_EQ(all.size(), 1u);
  // Tuple: (origin_string, PermissionType, PermissionStatus)
  EXPECT_EQ(std::get<0>(all[0]), MakeOrigin(kOriginA).Serialize());
  EXPECT_EQ(std::get<1>(all[0]), PermissionType::VIDEO_CAPTURE);
  EXPECT_EQ(std::get<2>(all[0]), PermissionStatus::GRANTED);
}

// AC-P1-2: ResetOrigin removes all permissions for that origin.
TEST_F(OWLPermissionManagerTest, ResetOriginRemovesAll) {
  auto origin = MakeOrigin(kOriginA);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(origin, PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);
  EXPECT_EQ(manager_->permission_count_for_testing(), 2u);

  manager_->ResetOrigin(origin);

  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::AUDIO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-2: ResetOrigin on non-existent origin is a safe no-op.
TEST_F(OWLPermissionManagerTest, ResetOriginNonExistentIsNoop) {
  manager_->ResetOrigin(MakeOrigin(kOriginA));
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-2: ResetOrigin does not affect other origins.
TEST_F(OWLPermissionManagerTest, ResetOriginDoesNotAffectOthers) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginB),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);

  manager_->ResetOrigin(MakeOrigin(kOriginA));

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginB),
                                    PermissionType::AUDIO_CAPTURE),
            PermissionStatus::DENIED);
}

// =============================================================================
// AC-P1-3: Permissions persist to JSON file and survive reload
// =============================================================================

// AC-P1-3: Happy path — set permissions, reload from same file, verify.
TEST_F(OWLPermissionManagerTest, PersistAndReload) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginB),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginB),
                                    PermissionType::AUDIO_CAPTURE),
            PermissionStatus::DENIED);
}

// AC-P1-3: Multiple permission types per origin survive reload.
TEST_F(OWLPermissionManagerTest, MultiplePermissionsPersistAndReload) {
  auto origin = MakeOrigin(kOriginMeet);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(origin, PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(origin, PermissionType::GEOLOCATION,
                          PermissionStatus::DENIED);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::AUDIO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::GEOLOCATION),
            PermissionStatus::DENIED);
}

// AC-P1-3: JSON file is created on disk after the first SetPermission.
TEST_F(OWLPermissionManagerTest, JsonFileCreatedOnSet) {
  EXPECT_FALSE(base::PathExists(permissions_path_));

  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);

  EXPECT_TRUE(base::PathExists(permissions_path_));
  std::string content = ReadRawFile();
  EXPECT_FALSE(content.empty());
}

// AC-P1-3: SetPermission(ASK) after GRANTED removes entry; removal persists.
TEST_F(OWLPermissionManagerTest, SetAskPersistsRemoval) {
  auto origin = MakeOrigin(kOriginA);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);

  // Revoke by setting ASK.
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::ASK);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-3: ResetOrigin persists the removal to disk.
TEST_F(OWLPermissionManagerTest, ResetOriginPersists) {
  auto origin = MakeOrigin(kOriginA);
  manager_->SetPermission(origin, PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->ResetOrigin(origin);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(origin, PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-3: Permission count survives reload correctly.
TEST_F(OWLPermissionManagerTest, PermissionCountSurvivesReload) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);
  manager_->SetPermission(MakeOrigin(kOriginB),
                          PermissionType::GEOLOCATION,
                          PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->permission_count_for_testing(), 3u);

  ReloadManager();

  EXPECT_EQ(manager_->permission_count_for_testing(), 3u);
}

// =============================================================================
// AC-P1-3: Memory-only mode (off-the-record / empty path)
// =============================================================================

// AC-P1-3: Empty path = memory-only; no file is created.
TEST_F(OWLPermissionManagerTest, OffTheRecordNoFile) {
  auto memory_manager =
      std::make_unique<OWLPermissionManager>(base::FilePath());

  memory_manager->SetPermission(MakeOrigin(kOriginA),
                                PermissionType::VIDEO_CAPTURE,
                                PermissionStatus::GRANTED);

  // Permission is stored in memory.
  EXPECT_EQ(memory_manager->GetPermission(MakeOrigin(kOriginA),
                                          PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);

  // No file should be created on disk.
  EXPECT_FALSE(base::PathExists(permissions_path_));
}

// =============================================================================
// AC-P1-4: Corrupt JSON — no crash, fallback to ASK
// =============================================================================

// AC-P1-4: Completely invalid JSON.
TEST_F(OWLPermissionManagerTest, CorruptJsonFallsBackToAsk) {
  WriteRawFile("this is not valid json {{{}}}}");

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-4: Empty file — no crash, treated as empty.
TEST_F(OWLPermissionManagerTest, EmptyFileFallsBackToAsk) {
  WriteRawFile("");

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-4: Valid JSON but wrong top-level structure (array, not object).
TEST_F(OWLPermissionManagerTest, WrongJsonStructureFallsBackToAsk) {
  WriteRawFile("[1, 2, 3]");

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// AC-P1-4: Unknown permission type string is skipped gracefully.
TEST_F(OWLPermissionManagerTest, UnknownPermissionTypeSkipped) {
  const char* json = R"({
    "https://example.com": {
      "camera": "granted",
      "unknown_perm": "granted"
    }
  })";
  WriteRawFile(json);

  ReloadManager();

  // "camera" should load.
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  // "unknown_perm" silently skipped — no crash.
}

// AC-P1-4: Invalid status value string for a known type is skipped.
TEST_F(OWLPermissionManagerTest, InvalidStatusValueSkipped) {
  const char* json = R"({
    "https://example.com": {
      "camera": "maybe"
    }
  })";
  WriteRawFile(json);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// AC-P1-4: Inner value is a non-string type (number).
TEST_F(OWLPermissionManagerTest, NonStringStatusValueSkipped) {
  const char* json = R"({
    "https://example.com": {
      "camera": 42
    }
  })";
  WriteRawFile(json);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// AC-P1-4: Origin value is not a dict (string instead).
TEST_F(OWLPermissionManagerTest, NonDictOriginValueSkipped) {
  const char* json = R"({
    "https://example.com": "not a dict"
  })";
  WriteRawFile(json);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// AC-P1-4: Partially valid JSON — valid entries load, broken ones skipped.
TEST_F(OWLPermissionManagerTest, PartiallyValidJsonLoadsValidEntries) {
  const char* json = R"({
    "https://example.com": {
      "camera": "granted",
      "microphone": "invalid_status"
    },
    "https://other.com": "not_a_dict",
    "https://meet.google.com": {
      "geolocation": "denied"
    }
  })";
  WriteRawFile(json);

  ReloadManager();

  // Valid entries loaded.
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginMeet),
                                    PermissionType::GEOLOCATION),
            PermissionStatus::DENIED);
  // Invalid entries skipped.
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::AUDIO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginB),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// AC-P1-4: Non-existent file is normal first-launch (not an error).
TEST_F(OWLPermissionManagerTest, NonExistentFileIsNormalStartup) {
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// AC-P1-4: After corrupt file load, SetPermission still works and creates
// valid JSON so subsequent reloads succeed.
TEST_F(OWLPermissionManagerTest, RecoveryAfterCorruptFile) {
  WriteRawFile("corrupt!!");
  ReloadManager();

  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);

  // Set a new permission (overwrites the corrupt file).
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);

  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
}

// =============================================================================
// AC-P1-5: BrowserContext returns PermissionControllerDelegate
// =============================================================================

// AC-P1-5: Non-OTR BrowserContext returns non-null delegate.
// DISABLED: OWLContentBrowserContext SEGVs without full Chromium init.
TEST(OWLContentBrowserContextIntegrationTest, DISABLED_PermissionDelegateNotNull) {
  base::test::SingleThreadTaskEnvironment task_environment;
  OWLContentBrowserContext ctx(/*off_the_record=*/false);
  EXPECT_NE(ctx.GetPermissionControllerDelegate(), nullptr);
}

// AC-P1-5: Off-the-record BrowserContext also returns non-null delegate.
// DISABLED: same reason.
TEST(OWLContentBrowserContextIntegrationTest,
     DISABLED_OffTheRecordPermissionDelegateNotNull) {
  base::test::SingleThreadTaskEnvironment task_environment;
  OWLContentBrowserContext ctx(/*off_the_record=*/true);
  EXPECT_NE(ctx.GetPermissionControllerDelegate(), nullptr);
}

// =============================================================================
// ResetPermission override (Chromium content layer callback path)
// =============================================================================

// Verify ResetPermission(PermissionType, GURL, GURL) override works correctly.
TEST_F(OWLPermissionManagerTest, ResetPermissionOverride) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  ASSERT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);

  // Call the Chromium override path (takes GURL, not url::Origin)
  manager_->ResetPermission(PermissionType::VIDEO_CAPTURE,
                            GURL(kOriginA), GURL(kOriginA));

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
}

// ResetPermission on non-existent entry does not crash.
TEST_F(OWLPermissionManagerTest, ResetPermissionOverrideNonExistent) {
  manager_->ResetPermission(PermissionType::VIDEO_CAPTURE,
                            GURL(kOriginA), GURL(kOriginA));
  EXPECT_EQ(manager_->permission_count_for_testing(), 0u);
}

// =============================================================================
// request_id lifecycle (Phase 2 pending request management)
// =============================================================================

// Helper: create a PermissionRequestDescription for a single permission type.
content::PermissionRequestDescription MakeRequestDescription(
    PermissionType type,
    const char* origin_url) {
  return content::PermissionRequestDescription(
      content::PermissionDescriptorUtil::
          CreatePermissionDescriptorForPermissionType(type),
      /*user_gesture=*/true, GURL(origin_url));
}

// Fixture with MOCK_TIME for testing pending request timeouts.
class OWLPermissionManagerMockTimeTest : public testing::Test {
 protected:
  void SetUp() override {
    manager_ =
        std::make_unique<OWLPermissionManager>(base::FilePath());
  }

  base::test::SingleThreadTaskEnvironment task_environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
  std::unique_ptr<OWLPermissionManager> manager_;
};

// AC-P2: RequestPermissions with ASK status creates a pending request,
// and ResolvePendingRequest runs the callback with the resolved status.
TEST_F(OWLPermissionManagerMockTimeTest,
       ResolvePendingRequest_ValidId_RunsCallback) {
  // Default permission is ASK, so RequestPermissions should pend.
  ASSERT_EQ(manager_->pending_request_count_for_testing(), 0u);

  bool callback_called = false;
  content::PermissionStatus received_status = PermissionStatus::ASK;

  manager_->RequestPermissions(
      /*render_frame_host=*/nullptr,
      MakeRequestDescription(PermissionType::VIDEO_CAPTURE, kOriginA),
      base::BindOnce(
          [](bool* called, content::PermissionStatus* out,
             const std::vector<content::PermissionResult>& results) {
            *called = true;
            if (!results.empty()) {
              *out = results[0].status;
            }
          },
          &callback_called, &received_status));

  EXPECT_EQ(manager_->pending_request_count_for_testing(), 1u);
  EXPECT_FALSE(callback_called);

  // Resolve with GRANTED — should invoke callback and remove from pending.
  manager_->ResolvePendingRequest(/*request_id=*/1,
                                  PermissionStatus::GRANTED);

  EXPECT_TRUE(callback_called);
  EXPECT_EQ(received_status, PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);
}

// AC-P2: ResolvePendingRequest with an unknown id is a silent no-op.
TEST_F(OWLPermissionManagerMockTimeTest,
       ResolvePendingRequest_UnknownId_Ignored) {
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);
  // Should not crash or have any side-effect.
  manager_->ResolvePendingRequest(/*request_id=*/999,
                                  PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);
}

// AC-P2: Double-resolving the same request_id — second call is ignored
// (idempotency).
TEST_F(OWLPermissionManagerMockTimeTest,
       ResolvePendingRequest_DoubleResolve_SecondIgnored) {
  int callback_count = 0;

  manager_->RequestPermissions(
      /*render_frame_host=*/nullptr,
      MakeRequestDescription(PermissionType::AUDIO_CAPTURE, kOriginA),
      base::BindOnce(
          [](int* count,
             const std::vector<content::PermissionResult>& results) {
            ++(*count);
          },
          &callback_count));

  ASSERT_EQ(manager_->pending_request_count_for_testing(), 1u);

  // First resolve — should invoke callback.
  manager_->ResolvePendingRequest(/*request_id=*/1,
                                  PermissionStatus::GRANTED);
  EXPECT_EQ(callback_count, 1);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);

  // Second resolve with same id — silent no-op, callback NOT called again.
  manager_->ResolvePendingRequest(/*request_id=*/1,
                                  PermissionStatus::DENIED);
  EXPECT_EQ(callback_count, 1);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);
}

// AC-P2: Pending request auto-denies after timeout (30s).
TEST_F(OWLPermissionManagerMockTimeTest, PendingRequest_TimeoutAutoDenies) {
  bool callback_called = false;
  content::PermissionStatus received_status = PermissionStatus::ASK;

  manager_->RequestPermissions(
      /*render_frame_host=*/nullptr,
      MakeRequestDescription(PermissionType::GEOLOCATION, kOriginA),
      base::BindOnce(
          [](bool* called, content::PermissionStatus* out,
             const std::vector<content::PermissionResult>& results) {
            *called = true;
            if (!results.empty()) {
              *out = results[0].status;
            }
          },
          &callback_called, &received_status));

  ASSERT_EQ(manager_->pending_request_count_for_testing(), 1u);
  EXPECT_FALSE(callback_called);

  // Advance time past the 30-second timeout.
  task_environment_.FastForwardBy(base::Seconds(30));

  EXPECT_TRUE(callback_called);
  EXPECT_EQ(received_status, PermissionStatus::DENIED);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);
}

// AC-P2: Multiple concurrent pending requests are independent —
// resolving one does not affect the others.
TEST_F(OWLPermissionManagerMockTimeTest,
       MultiplePendingRequests_Independent) {
  bool cb1_called = false;
  bool cb2_called = false;
  bool cb3_called = false;
  content::PermissionStatus status1 = PermissionStatus::ASK;
  content::PermissionStatus status2 = PermissionStatus::ASK;
  content::PermissionStatus status3 = PermissionStatus::ASK;

  // Request 1: VIDEO_CAPTURE on origin A.
  manager_->RequestPermissions(
      /*render_frame_host=*/nullptr,
      MakeRequestDescription(PermissionType::VIDEO_CAPTURE, kOriginA),
      base::BindOnce(
          [](bool* called, content::PermissionStatus* out,
             const std::vector<content::PermissionResult>& results) {
            *called = true;
            if (!results.empty()) *out = results[0].status;
          },
          &cb1_called, &status1));

  // Request 2: AUDIO_CAPTURE on origin A.
  manager_->RequestPermissions(
      /*render_frame_host=*/nullptr,
      MakeRequestDescription(PermissionType::AUDIO_CAPTURE, kOriginA),
      base::BindOnce(
          [](bool* called, content::PermissionStatus* out,
             const std::vector<content::PermissionResult>& results) {
            *called = true;
            if (!results.empty()) *out = results[0].status;
          },
          &cb2_called, &status2));

  // Request 3: VIDEO_CAPTURE on origin B.
  manager_->RequestPermissions(
      /*render_frame_host=*/nullptr,
      MakeRequestDescription(PermissionType::VIDEO_CAPTURE, kOriginB),
      base::BindOnce(
          [](bool* called, content::PermissionStatus* out,
             const std::vector<content::PermissionResult>& results) {
            *called = true;
            if (!results.empty()) *out = results[0].status;
          },
          &cb3_called, &status3));

  ASSERT_EQ(manager_->pending_request_count_for_testing(), 3u);

  // Resolve request 2 only (id=2).
  manager_->ResolvePendingRequest(/*request_id=*/2,
                                  PermissionStatus::GRANTED);

  EXPECT_FALSE(cb1_called);
  EXPECT_TRUE(cb2_called);
  EXPECT_FALSE(cb3_called);
  EXPECT_EQ(status2, PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 2u);

  // Resolve request 1 (id=1) with DENIED.
  manager_->ResolvePendingRequest(/*request_id=*/1,
                                  PermissionStatus::DENIED);

  EXPECT_TRUE(cb1_called);
  EXPECT_FALSE(cb3_called);
  EXPECT_EQ(status1, PermissionStatus::DENIED);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 1u);

  // Request 3 (id=3) should auto-deny on timeout.
  task_environment_.FastForwardBy(base::Seconds(30));

  EXPECT_TRUE(cb3_called);
  EXPECT_EQ(status3, PermissionStatus::DENIED);
  EXPECT_EQ(manager_->pending_request_count_for_testing(), 0u);
}

// =============================================================================
// BH-017: PersistNow async write produces complete file
// =============================================================================

// AC-3: PersistNow writes a valid JSON file to disk.
TEST_F(OWLPermissionManagerTest, PersistNowWritesValidJson) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginB),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);

  // Explicitly call PersistNow (in production this is async; in tests
  // it runs synchronously on the same thread).
  manager_->PersistNow();

  // Verify the file exists and contains valid JSON.
  std::string content = ReadRawFile();
  ASSERT_FALSE(content.empty()) << "PersistNow should write a non-empty file";

  auto parsed = base::JSONReader::Read(content, base::JSON_PARSE_RFC);
  ASSERT_TRUE(parsed.has_value())
      << "PersistNow output should be valid JSON, got: " << content;
  ASSERT_TRUE(parsed->is_dict())
      << "Top-level JSON should be a dict";
}

// AC-3: PersistNow file contains all set permissions (completeness).
TEST_F(OWLPermissionManagerTest, PersistNowFileIsComplete) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);
  manager_->SetPermission(MakeOrigin(kOriginB),
                          PermissionType::GEOLOCATION,
                          PermissionStatus::GRANTED);

  manager_->PersistNow();

  // Reload from file and verify all permissions survived.
  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::AUDIO_CAPTURE),
            PermissionStatus::DENIED);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginB),
                                    PermissionType::GEOLOCATION),
            PermissionStatus::GRANTED);
  EXPECT_EQ(manager_->permission_count_for_testing(), 3u);
}

// AC-3: PersistNow after removing a permission writes a correct
// (reduced) file — no stale entries remain.
TEST_F(OWLPermissionManagerTest, PersistNowAfterRemoval) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::AUDIO_CAPTURE,
                          PermissionStatus::DENIED);
  manager_->PersistNow();

  // Remove one permission by setting to ASK.
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::ASK);
  manager_->PersistNow();

  // Reload and verify only the remaining permission is present.
  ReloadManager();

  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::VIDEO_CAPTURE),
            PermissionStatus::ASK);
  EXPECT_EQ(manager_->GetPermission(MakeOrigin(kOriginA),
                                    PermissionType::AUDIO_CAPTURE),
            PermissionStatus::DENIED);
  EXPECT_EQ(manager_->permission_count_for_testing(), 1u);
}

// AC-3: PersistNow on empty permission set produces valid (empty object) JSON.
TEST_F(OWLPermissionManagerTest, PersistNowEmptyStoreWritesValidJson) {
  // No permissions set — PersistNow should still write a valid file.
  manager_->PersistNow();

  std::string content = ReadRawFile();
  // An empty store may write "{}" or not write a file at all.
  // If it writes, it should be valid JSON.
  if (!content.empty()) {
    auto parsed = base::JSONReader::Read(content, base::JSON_PARSE_RFC);
    EXPECT_TRUE(parsed.has_value())
        << "Even an empty store should produce valid JSON, got: " << content;
  }
}

// AC-3: PersistNow is idempotent — calling it twice produces the same file.
TEST_F(OWLPermissionManagerTest, PersistNowIdempotent) {
  manager_->SetPermission(MakeOrigin(kOriginA),
                          PermissionType::VIDEO_CAPTURE,
                          PermissionStatus::GRANTED);

  manager_->PersistNow();
  std::string first_content = ReadRawFile();

  manager_->PersistNow();
  std::string second_content = ReadRawFile();

  EXPECT_EQ(first_content, second_content)
      << "Two consecutive PersistNow calls should produce identical files";
}

}  // namespace
}  // namespace owl
