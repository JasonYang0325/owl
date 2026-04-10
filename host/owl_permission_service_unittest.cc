// Copyright 2026 AntlerAI. All rights reserved.
// Unit tests for OWLPermissionServiceImpl (Phase 2 Mojom PermissionService).
// Tests are organized by AC (Acceptance Criteria) from
// phase-2-mojom-bridge.md.

#include "third_party/owl/host/owl_permission_service_impl.h"

#include <string>
#include <vector>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_permission_manager.h"
#include "third_party/owl/mojom/permissions.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace owl {
namespace {

// Aliases for readability.
using MojomPermissionType = owl::mojom::PermissionType;
using MojomPermissionStatus = owl::mojom::PermissionStatus;
using MojomSitePermissionPtr = owl::mojom::SitePermissionPtr;
using BlinkPermissionType = blink::PermissionType;
using ContentPermissionStatus = content::PermissionStatus;

const char kOriginA[] = "https://example.com";
const char kOriginB[] = "https://other.com";
const char kOriginC[] = "https://third.example.org";

url::Origin MakeOrigin(const char* url_str) {
  return url::Origin::Create(GURL(url_str));
}

// =============================================================================
// Fixture: PermissionServiceImpl backed by a real OWLPermissionManager
// (memory-only mode, no file I/O). Mojo remote exercises the full IPC path.
// =============================================================================

class OWLPermissionServiceImplTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool init = [] {
      mojo::core::Init();
      return true;
    }();
    (void)init;
  }

  void SetUp() override {
    // Memory-only mode (empty path): no file persistence, suitable for tests.
    manager_ = std::make_unique<OWLPermissionManager>(base::FilePath());
    service_ = std::make_unique<OWLPermissionServiceImpl>(manager_.get());
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  // Pre-populate a permission via the underlying manager (bypasses Mojo).
  void SeedPermission(const char* origin,
                      BlinkPermissionType type,
                      ContentPermissionStatus status) {
    manager_->SetPermission(MakeOrigin(origin), type, status);
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLPermissionManager> manager_;
  std::unique_ptr<OWLPermissionServiceImpl> service_;
  mojo::Remote<owl::mojom::PermissionService> remote_;
};

// =============================================================================
// AC-P2-1: Mojom PermissionService compiles and binds
//   (These tests exercise the Mojo binding; compilation is verified by the
//    fact that this file compiles and the fixture SetUp succeeds.)
// =============================================================================

// AC-P2-1: Happy path — Mojo remote is bound and usable.
TEST_F(OWLPermissionServiceImplTest, MojoBindingSucceeds) {
  EXPECT_TRUE(remote_.is_bound());
  EXPECT_TRUE(remote_.is_connected());
}

// AC-P2-1: GetPermission round-trips through Mojo without crash.
TEST_F(OWLPermissionServiceImplTest, GetPermissionRoundTrip) {
  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            // Unset permission should return kAsk.
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// =============================================================================
// AC-P2-4: PermissionGetAll returns all persisted permissions
// =============================================================================

// AC-P2-4: Happy path — GetAllPermissions returns seeded permissions.
TEST_F(OWLPermissionServiceImplTest, GetAllReturnsSeededPermissions) {
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::GRANTED);
  SeedPermission(kOriginB, BlinkPermissionType::AUDIO_CAPTURE,
                 ContentPermissionStatus::DENIED);

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        ASSERT_EQ(permissions.size(), 2u);

        // Verify both entries exist (order is not guaranteed by map iteration).
        bool found_a = false, found_b = false;
        for (const auto& p : permissions) {
          if (p->origin == "https://example.com" &&
              p->type == MojomPermissionType::kCamera &&
              p->status == MojomPermissionStatus::kGranted) {
            found_a = true;
          }
          if (p->origin == "https://other.com" &&
              p->type == MojomPermissionType::kMicrophone &&
              p->status == MojomPermissionStatus::kDenied) {
            found_b = true;
          }
        }
        EXPECT_TRUE(found_a) << "Missing example.com camera granted";
        EXPECT_TRUE(found_b) << "Missing other.com microphone denied";
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-4: Empty — no permissions returns empty array.
TEST_F(OWLPermissionServiceImplTest, GetAllReturnsEmptyWhenNoPermissions) {
  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_TRUE(permissions.empty());
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-4: All four permission types are returned.
TEST_F(OWLPermissionServiceImplTest, GetAllReturnsFourTypes) {
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::GRANTED);
  SeedPermission(kOriginA, BlinkPermissionType::AUDIO_CAPTURE,
                 ContentPermissionStatus::DENIED);
  SeedPermission(kOriginA, BlinkPermissionType::GEOLOCATION,
                 ContentPermissionStatus::GRANTED);
  SeedPermission(kOriginA, BlinkPermissionType::NOTIFICATIONS,
                 ContentPermissionStatus::DENIED);

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_EQ(permissions.size(), 4u);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-4: Permissions for multiple origins are all returned.
TEST_F(OWLPermissionServiceImplTest, GetAllReturnsMultipleOrigins) {
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::GRANTED);
  SeedPermission(kOriginB, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::DENIED);
  SeedPermission(kOriginC, BlinkPermissionType::GEOLOCATION,
                 ContentPermissionStatus::GRANTED);

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_EQ(permissions.size(), 3u);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-4: ASK entries are not included in GetAll (ASK is the default,
// not persisted).
TEST_F(OWLPermissionServiceImplTest, GetAllExcludesAskEntries) {
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::GRANTED);
  // Setting ASK removes the entry from the store.
  SeedPermission(kOriginB, BlinkPermissionType::AUDIO_CAPTURE,
                 ContentPermissionStatus::ASK);

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        // Only the GRANTED entry should be present; ASK is not stored.
        EXPECT_EQ(permissions.size(), 1u);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// =============================================================================
// AC-P2-2/3: SetPermission via Mojo -> PermissionManager, then GetPermission
//   AC-P2-2: Host -> Observer -> C-ABI callback (SetPermission writes to mgr)
//   AC-P2-3: C-ABI -> Mojo -> Host (GetPermission reads back)
//   These tests verify the CRUD path through the Mojo PermissionService.
// =============================================================================

// AC-P2-2/3: Happy path — SetPermission(GRANTED) then GetPermission returns
// GRANTED.
TEST_F(OWLPermissionServiceImplTest, SetThenGetReturnsGranted) {
  // SetPermission is fire-and-forget (no callback), so we must flush.
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2/3: SetPermission(DENIED) then GetPermission returns DENIED.
TEST_F(OWLPermissionServiceImplTest, SetThenGetReturnsDenied) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kMicrophone,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kDenied);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2/3: Overwrite DENIED with GRANTED.
TEST_F(OWLPermissionServiceImplTest, OverwritePermission) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2/3: Set ASK is equivalent to removing the entry.
TEST_F(OWLPermissionServiceImplTest, SetAskRemovesEntry) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Setting ASK should remove the entry.
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kAsk);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Verify GetAll also excludes it.
  base::RunLoop loop2;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_TRUE(permissions.empty());
        l->Quit();
      },
      &loop2));
  loop2.Run();
}

// AC-P2-2/3: Unset permission returns kAsk (default).
TEST_F(OWLPermissionServiceImplTest, UnsetPermissionReturnsAsk) {
  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kGeolocation,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2/3: Different origins have independent permissions.
TEST_F(OWLPermissionServiceImplTest, DifferentOriginsAreIndependent) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginB, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  base::RunLoop loop_a;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop_a));
  loop_a.Run();

  base::RunLoop loop_b;
  remote_->GetPermission(
      kOriginB, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kDenied);
            l->Quit();
          },
          &loop_b));
  loop_b.Run();
}

// AC-P2-2/3: Different permission types for same origin are independent.
TEST_F(OWLPermissionServiceImplTest, DifferentTypesAreIndependent) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  base::RunLoop loop1;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop1));
  loop1.Run();

  base::RunLoop loop2;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kMicrophone,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kDenied);
            l->Quit();
          },
          &loop2));
  loop2.Run();
}

// AC-P2-2/3: All four Mojom PermissionTypes are correctly mapped.
TEST_F(OWLPermissionServiceImplTest, AllFourPermissionTypesMapped) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kGeolocation,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kNotifications,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Verify via underlying manager that blink types are correct.
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::VIDEO_CAPTURE),
      ContentPermissionStatus::GRANTED);
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::AUDIO_CAPTURE),
      ContentPermissionStatus::GRANTED);
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::GEOLOCATION),
      ContentPermissionStatus::GRANTED);
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::NOTIFICATIONS),
      ContentPermissionStatus::GRANTED);
}

// AC-P2-2/3: SetPermission writes through to underlying PermissionManager.
TEST_F(OWLPermissionServiceImplTest, SetPermissionWritesToManager) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Verify directly via manager (bypassing Mojo).
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::VIDEO_CAPTURE),
      ContentPermissionStatus::GRANTED);
}

// =============================================================================
// AC-P2-5: PermissionReset clears the specified permission
// =============================================================================

// AC-P2-5: Happy path — ResetPermission reverts to kAsk.
TEST_F(OWLPermissionServiceImplTest, ResetPermissionRevertsToAsk) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Reset is fire-and-forget.
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-5: ResetPermission only affects the specified type, not others.
TEST_F(OWLPermissionServiceImplTest, ResetOnlyAffectsSpecifiedType) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  // Reset only camera.
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_.FlushForTesting();

  base::RunLoop loop1;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop1));
  loop1.Run();

  // Microphone should be unaffected.
  base::RunLoop loop2;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kMicrophone,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kDenied);
            l->Quit();
          },
          &loop2));
  loop2.Run();
}

// AC-P2-5: ResetPermission only affects the specified origin, not others.
TEST_F(OWLPermissionServiceImplTest, ResetOnlyAffectsSpecifiedOrigin) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginB, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Reset only origin A.
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_.FlushForTesting();

  base::RunLoop loop1;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop1));
  loop1.Run();

  // Origin B should be unaffected.
  base::RunLoop loop2;
  remote_->GetPermission(
      kOriginB, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop2));
  loop2.Run();
}

// AC-P2-5: ResetPermission on non-existent entry is a no-op (no crash).
TEST_F(OWLPermissionServiceImplTest, ResetNonexistentIsNoop) {
  // Should not crash or error.
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-5: Double reset of the same permission is a no-op (no crash).
TEST_F(OWLPermissionServiceImplTest, DoubleResetIsNoop) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Reset twice.
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-5: ResetAll clears all permissions for all origins.
TEST_F(OWLPermissionServiceImplTest, ResetAllClearsEverything) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_->SetPermission(kOriginB, MojomPermissionType::kGeolocation,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Reset all.
  remote_->ResetAll();
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_TRUE(permissions.empty());
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-5: ResetAll on empty store is a no-op (no crash).
TEST_F(OWLPermissionServiceImplTest, ResetAllOnEmptyIsNoop) {
  remote_->ResetAll();
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_TRUE(permissions.empty());
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-5: After ResetAll, individual GetPermission returns kAsk.
TEST_F(OWLPermissionServiceImplTest, ResetAllThenGetReturnsAsk) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  remote_->ResetAll();
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// =============================================================================
// AC-P2-2: Permission request from Host -> Observer -> C-ABI callback
// This section tests the type conversion utilities and the request flow.
//
// NOTE: AC-P2-2 end-to-end coverage (OnPermissionRequest -> Bridge observer
// -> C-ABI callback -> Swift UI) cannot be tested in pure C++ GTest because
// the callback chain crosses into ObjC++ Bridge layer (OWLBridgeSession).
// The full OnPermissionRequest -> OWLBridge_RespondToPermission round-trip
// is covered by pipeline tests (OWLBrowserTests) which run the real Host
// process with OWLBridge.framework loaded.
// =============================================================================

// AC-P2-2: Mojom type -> blink type conversion (Camera -> VIDEO_CAPTURE).
TEST_F(OWLPermissionServiceImplTest, TypeConversionCameraToVideoCap) {
  // Set via Mojom, verify via manager (blink type).
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::VIDEO_CAPTURE),
      ContentPermissionStatus::GRANTED);
}

// AC-P2-2: Mojom type -> blink type conversion (Microphone -> AUDIO_CAPTURE).
TEST_F(OWLPermissionServiceImplTest, TypeConversionMicToAudioCap) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::AUDIO_CAPTURE),
      ContentPermissionStatus::DENIED);
}

// AC-P2-2: Mojom type -> blink type conversion (Geolocation -> GEOLOCATION).
TEST_F(OWLPermissionServiceImplTest, TypeConversionGeolocation) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kGeolocation,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::GEOLOCATION),
      ContentPermissionStatus::GRANTED);
}

// AC-P2-2: Mojom type -> blink type conversion (Notifications -> NOTIFICATIONS).
TEST_F(OWLPermissionServiceImplTest, TypeConversionNotifications) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kNotifications,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();
  EXPECT_EQ(
      manager_->GetPermission(MakeOrigin(kOriginA),
                              BlinkPermissionType::NOTIFICATIONS),
      ContentPermissionStatus::GRANTED);
}

// AC-P2-2: blink type -> Mojom type conversion (via GetPermission on seeded
// data).
TEST_F(OWLPermissionServiceImplTest, BlinkToMojomTypeConversion) {
  // Seed via manager (blink types), read back via Mojo.
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::GRANTED);

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2: Status conversion: GRANTED <-> kGranted.
TEST_F(OWLPermissionServiceImplTest, StatusConversionGranted) {
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::GRANTED);

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2: Status conversion: DENIED <-> kDenied.
TEST_F(OWLPermissionServiceImplTest, StatusConversionDenied) {
  SeedPermission(kOriginA, BlinkPermissionType::VIDEO_CAPTURE,
                 ContentPermissionStatus::DENIED);

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kDenied);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-2: Status conversion: ASK <-> kAsk (default for unset).
TEST_F(OWLPermissionServiceImplTest, StatusConversionAsk) {
  // Don't seed -- unset permission should return ASK.
  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// =============================================================================
// AC-P2-3: RespondToPermission from C-ABI -> Mojo -> Host
// These tests verify that permission decisions propagate correctly.
// =============================================================================

// AC-P2-3: Happy path — SetPermission(GRANTED) is visible through GetAll.
TEST_F(OWLPermissionServiceImplTest, RespondGrantedVisibleInGetAll) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        ASSERT_EQ(permissions.size(), 1u);
        EXPECT_EQ(permissions[0]->origin, "https://example.com");
        EXPECT_EQ(permissions[0]->type, MojomPermissionType::kCamera);
        EXPECT_EQ(permissions[0]->status, MojomPermissionStatus::kGranted);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-3: SetPermission(DENIED) is visible through GetAll.
TEST_F(OWLPermissionServiceImplTest, RespondDeniedVisibleInGetAll) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        ASSERT_EQ(permissions.size(), 1u);
        EXPECT_EQ(permissions[0]->status, MojomPermissionStatus::kDenied);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-3: Multiple sequential Set+Get cycles work correctly (no stale state).
TEST_F(OWLPermissionServiceImplTest, SequentialSetGetCycles) {
  // Cycle 1: Set GRANTED.
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();
  {
    base::RunLoop loop;
    remote_->GetPermission(
        kOriginA, MojomPermissionType::kCamera,
        base::BindOnce(
            [](base::RunLoop* l, MojomPermissionStatus status) {
              EXPECT_EQ(status, MojomPermissionStatus::kGranted);
              l->Quit();
            },
            &loop));
    loop.Run();
  }

  // Cycle 2: Overwrite to DENIED.
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();
  {
    base::RunLoop loop;
    remote_->GetPermission(
        kOriginA, MojomPermissionType::kCamera,
        base::BindOnce(
            [](base::RunLoop* l, MojomPermissionStatus status) {
              EXPECT_EQ(status, MojomPermissionStatus::kDenied);
              l->Quit();
            },
            &loop));
    loop.Run();
  }

  // Cycle 3: Reset to ASK.
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kAsk);
  remote_.FlushForTesting();
  {
    base::RunLoop loop;
    remote_->GetPermission(
        kOriginA, MojomPermissionType::kCamera,
        base::BindOnce(
            [](base::RunLoop* l, MojomPermissionStatus status) {
              EXPECT_EQ(status, MojomPermissionStatus::kAsk);
              l->Quit();
            },
            &loop));
    loop.Run();
  }
}

// =============================================================================
// Edge cases and error paths
// =============================================================================

// AC-P2-2: Empty origin string — should not crash, permission stored with
// opaque origin representation.
TEST_F(OWLPermissionServiceImplTest, EmptyOriginString) {
  remote_->SetPermission("", MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      "", MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            // Empty origin creates an opaque origin. The exact behavior
            // depends on OWLPermissionManager's handling, but it must not
            // crash. The status may be kAsk (if opaque origins are
            // rejected) or kGranted (if stored).
            EXPECT_TRUE(status == MojomPermissionStatus::kAsk ||
                        status == MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-4: GetAll after mixed Set/Reset operations returns consistent state.
TEST_F(OWLPermissionServiceImplTest, GetAllAfterMixedOperations) {
  // Add several permissions.
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_->SetPermission(kOriginB, MojomPermissionType::kGeolocation,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Reset one, overwrite one.
  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        // Should have 2 entries: originA/mic=GRANTED, originB/geo=GRANTED.
        // originA/camera was reset (removed).
        ASSERT_EQ(permissions.size(), 2u);

        bool found_mic = false, found_geo = false;
        for (const auto& p : permissions) {
          if (p->origin == "https://example.com" &&
              p->type == MojomPermissionType::kMicrophone) {
            EXPECT_EQ(p->status, MojomPermissionStatus::kGranted);
            found_mic = true;
          }
          if (p->origin == "https://other.com" &&
              p->type == MojomPermissionType::kGeolocation) {
            EXPECT_EQ(p->status, MojomPermissionStatus::kGranted);
            found_geo = true;
          }
        }
        EXPECT_TRUE(found_mic) << "Missing example.com/microphone";
        EXPECT_TRUE(found_geo) << "Missing other.com/geolocation";
        l->Quit();
      },
      &loop));
  loop.Run();
}

// =============================================================================
// Fixture with MOCK_TIME for timeout tests (AC-P2-2/3 timeout behavior)
// =============================================================================

class OWLPermissionServiceImplTimeoutTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool init = [] {
      mojo::core::Init();
      return true;
    }();
    (void)init;
  }

  void SetUp() override {
    manager_ = std::make_unique<OWLPermissionManager>(base::FilePath());
    service_ = std::make_unique<OWLPermissionServiceImpl>(manager_.get());
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  base::test::SingleThreadTaskEnvironment task_environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
  std::unique_ptr<OWLPermissionManager> manager_;
  std::unique_ptr<OWLPermissionServiceImpl> service_;
  mojo::Remote<owl::mojom::PermissionService> remote_;
};

// AC-P2-2: Mojo calls still work correctly with mock time (sanity check).
TEST_F(OWLPermissionServiceImplTimeoutTest, MojoCallsWithMockTime) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-3: After fast-forward past timeout window, state remains consistent.
// (Verifies that PermissionService CRUD is not affected by time advancement.)
TEST_F(OWLPermissionServiceImplTimeoutTest,
       CRUDConsistentAfterTimeAdvancement) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  // Fast-forward 60 seconds (past the 30s permission request timeout).
  task_environment_.FastForwardBy(base::Seconds(60));

  // Permission should still be there.
  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kGranted);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-5: ResetAll after time advancement still works.
TEST_F(OWLPermissionServiceImplTimeoutTest, ResetAllAfterTimeAdvancement) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginB, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  task_environment_.FastForwardBy(base::Seconds(30));

  remote_->ResetAll();
  remote_.FlushForTesting();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_TRUE(permissions.empty());
        l->Quit();
      },
      &loop));
  loop.Run();
}

// =============================================================================
// Fixture with file-backed PermissionManager (persistence tests)
// =============================================================================

class OWLPermissionServiceImplPersistTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool init = [] {
      mojo::core::Init();
      return true;
    }();
    (void)init;
  }

  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    permissions_path_ = temp_dir_.GetPath().AppendASCII("permissions.json");
    manager_ = std::make_unique<OWLPermissionManager>(permissions_path_);
    service_ = std::make_unique<OWLPermissionServiceImpl>(manager_.get());
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  // Simulate restart: destroy service + manager, recreate from same file.
  void RestartService() {
    remote_.reset();
    service_.reset();
    manager_->PersistNow();
    manager_.reset();

    manager_ = std::make_unique<OWLPermissionManager>(permissions_path_);
    manager_->LoadFromFile();
    service_ = std::make_unique<OWLPermissionServiceImpl>(manager_.get());
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  base::ScopedTempDir temp_dir_;
  base::FilePath permissions_path_;
  std::unique_ptr<OWLPermissionManager> manager_;
  std::unique_ptr<OWLPermissionServiceImpl> service_;
  mojo::Remote<owl::mojom::PermissionService> remote_;
};

// AC-P2-4: Permissions survive restart (set via Mojo, read back after restart).
TEST_F(OWLPermissionServiceImplPersistTest, PermissionsSurviveRestart) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginB, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  RestartService();

  // Verify via GetPermission after restart.
  {
    base::RunLoop loop;
    remote_->GetPermission(
        kOriginA, MojomPermissionType::kCamera,
        base::BindOnce(
            [](base::RunLoop* l, MojomPermissionStatus status) {
              EXPECT_EQ(status, MojomPermissionStatus::kGranted);
              l->Quit();
            },
            &loop));
    loop.Run();
  }
  {
    base::RunLoop loop;
    remote_->GetPermission(
        kOriginB, MojomPermissionType::kMicrophone,
        base::BindOnce(
            [](base::RunLoop* l, MojomPermissionStatus status) {
              EXPECT_EQ(status, MojomPermissionStatus::kDenied);
              l->Quit();
            },
            &loop));
    loop.Run();
  }
}

// AC-P2-5: ResetPermission via Mojo persists across restart.
TEST_F(OWLPermissionServiceImplPersistTest, ResetPersistsAcrossRestart) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_.FlushForTesting();

  remote_->ResetPermission(kOriginA, MojomPermissionType::kCamera);
  remote_.FlushForTesting();

  RestartService();

  base::RunLoop loop;
  remote_->GetPermission(
      kOriginA, MojomPermissionType::kCamera,
      base::BindOnce(
          [](base::RunLoop* l, MojomPermissionStatus status) {
            EXPECT_EQ(status, MojomPermissionStatus::kAsk);
            l->Quit();
          },
          &loop));
  loop.Run();
}

// AC-P2-5: ResetAll persists across restart.
TEST_F(OWLPermissionServiceImplPersistTest, ResetAllPersistsAcrossRestart) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginB, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  remote_->ResetAll();
  remote_.FlushForTesting();

  RestartService();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_TRUE(permissions.empty());
        l->Quit();
      },
      &loop));
  loop.Run();
}

// AC-P2-4: GetAllPermissions after restart returns correct data.
TEST_F(OWLPermissionServiceImplPersistTest, GetAllAfterRestart) {
  remote_->SetPermission(kOriginA, MojomPermissionType::kCamera,
                         MojomPermissionStatus::kGranted);
  remote_->SetPermission(kOriginA, MojomPermissionType::kMicrophone,
                         MojomPermissionStatus::kDenied);
  remote_.FlushForTesting();

  RestartService();

  base::RunLoop loop;
  remote_->GetAllPermissions(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<MojomSitePermissionPtr> permissions) {
        EXPECT_EQ(permissions.size(), 2u);
        l->Quit();
      },
      &loop));
  loop.Run();
}

}  // namespace
}  // namespace owl
