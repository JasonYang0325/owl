// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

// StorageService unit tests.
// Tests cover: GetCookieDomains (empty / multi-domain aggregation),
// DeleteCookiesForDomain (valid / nonexistent), ClearBrowsingData
// (cookies-only / all-types / invalid-mask / zero-mask / time-range-ignored),
// GetStorageUsage (empty / sorted / overwrite-same-origin).

#include "third_party/owl/host/owl_storage_service.h"

#include <string>
#include <vector>

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/mojom/storage.mojom.h"

namespace owl {
namespace {

class OWLStorageServiceTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool init = [] {
      mojo::core::Init();
      return true;
    }();
    (void)init;
  }

  void SetUp() override {
    service_ = std::make_unique<OWLStorageService>();
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLStorageService> service_;
  mojo::Remote<owl::mojom::StorageService> remote_;
};

// 1. No cookies -> empty domain list.
TEST_F(OWLStorageServiceTest, StorageService_GetCookieDomains_Empty) {
  base::RunLoop loop;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        EXPECT_EQ(domains.size(), 0u);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// 2. Multiple domains are returned with correct aggregated counts.
TEST_F(OWLStorageServiceTest, StorageService_GetCookieDomains_MultipleDomains) {
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("google.com");
  service_->AddCookieForTesting("github.com");
  service_->AddCookieForTesting("github.com");

  base::RunLoop loop;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        ASSERT_EQ(domains.size(), 3u);
        // Results are sorted alphabetically by domain.
        EXPECT_EQ(domains[0]->domain, "example.com");
        EXPECT_EQ(domains[0]->cookie_count, 3);
        EXPECT_EQ(domains[1]->domain, "github.com");
        EXPECT_EQ(domains[1]->cookie_count, 2);
        EXPECT_EQ(domains[2]->domain, "google.com");
        EXPECT_EQ(domains[2]->cookie_count, 1);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// 3. Deleting cookies for a valid domain returns the deleted count.
TEST_F(OWLStorageServiceTest, StorageService_DeleteCookies_ValidDomain) {
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("other.com");

  base::RunLoop loop;
  remote_->DeleteCookiesForDomain(
      "example.com",
      base::BindOnce(
          [](base::RunLoop* l, int32_t deleted_count) {
            EXPECT_EQ(deleted_count, 3);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Verify: "example.com" is gone, "other.com" remains.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        ASSERT_EQ(domains.size(), 1u);
        EXPECT_EQ(domains[0]->domain, "other.com");
        EXPECT_EQ(domains[0]->cookie_count, 1);
        l->Quit();
      },
      &loop2));
  loop2.Run();
}

// 4. Deleting cookies for a nonexistent domain returns 0.
TEST_F(OWLStorageServiceTest, StorageService_DeleteCookies_NonexistentDomain) {
  service_->AddCookieForTesting("example.com");

  base::RunLoop loop;
  remote_->DeleteCookiesForDomain(
      "nonexistent.com",
      base::BindOnce(
          [](base::RunLoop* l, int32_t deleted_count) {
            EXPECT_EQ(deleted_count, 0);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Original cookies are untouched.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        ASSERT_EQ(domains.size(), 1u);
        EXPECT_EQ(domains[0]->domain, "example.com");
        l->Quit();
      },
      &loop2));
  loop2.Run();
}

// 5. ClearBrowsingData with cookies-only flag clears only cookies.
TEST_F(OWLStorageServiceTest, StorageService_ClearData_CookiesOnly) {
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("google.com");
  service_->AddStorageUsageForTesting("https://example.com", 1024);

  base::RunLoop loop;
  remote_->ClearBrowsingData(
      owl::mojom::kDataTypeCookies, 0.0, 0.0,
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            EXPECT_TRUE(success);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Cookies should be cleared.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        EXPECT_EQ(domains.size(), 0u);
        l->Quit();
      },
      &loop2));
  loop2.Run();

  // Storage usage should remain.
  base::RunLoop loop3;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        EXPECT_EQ(usage.size(), 1u);
        l->Quit();
      },
      &loop3));
  loop3.Run();
}

// 6. ClearBrowsingData with all types clears everything.
TEST_F(OWLStorageServiceTest, StorageService_ClearData_AllTypes) {
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("google.com");
  service_->AddStorageUsageForTesting("https://example.com", 2048);
  service_->AddStorageUsageForTesting("https://google.com", 4096);

  // All known bits: kCookies | kCache | kLocalStorage | kSessionStorage |
  // kIndexedDB = 0x1F.
  base::RunLoop loop;
  remote_->ClearBrowsingData(
      OWLStorageService::kAllDataTypes, 0.0, 0.0,
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            EXPECT_TRUE(success);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Both cookies and storage usage should be cleared.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        EXPECT_EQ(domains.size(), 0u);
        l->Quit();
      },
      &loop2));
  loop2.Run();

  base::RunLoop loop3;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        EXPECT_EQ(usage.size(), 0u);
        l->Quit();
      },
      &loop3));
  loop3.Run();
}

// 7. GetStorageUsage returns empty when no data has been added.
TEST_F(OWLStorageServiceTest, StorageService_GetUsage_Empty) {
  base::RunLoop loop;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        EXPECT_EQ(usage.size(), 0u);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// 8. ClearBrowsingData with invalid mask (unknown bits set) returns false.
TEST_F(OWLStorageServiceTest, StorageService_ClearData_InvalidMask) {
  service_->AddCookieForTesting("example.com");

  // 0x80 has no defined meaning — should be rejected.
  base::RunLoop loop;
  remote_->ClearBrowsingData(
      0x80, 0.0, 0.0,
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            EXPECT_FALSE(success);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Data should remain untouched after invalid request.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        ASSERT_EQ(domains.size(), 1u);
        EXPECT_EQ(domains[0]->domain, "example.com");
        l->Quit();
      },
      &loop2));
  loop2.Run();
}

// 9. ClearBrowsingData with data_types=0 is rejected (no valid bits set)
// and does not clear any data.
TEST_F(OWLStorageServiceTest, StorageService_ClearData_ZeroMask) {
  service_->AddCookieForTesting("example.com");
  service_->AddCookieForTesting("google.com");
  service_->AddStorageUsageForTesting("https://example.com", 1024);

  base::RunLoop loop;
  remote_->ClearBrowsingData(
      0, 0.0, 0.0,
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            // Zero mask has no valid data-type bits — treated as invalid.
            EXPECT_FALSE(success);
            l->Quit();
          },
          &loop));
  loop.Run();

  // Data should remain untouched after rejected request.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        ASSERT_EQ(domains.size(), 2u);
        l->Quit();
      },
      &loop2));
  loop2.Run();

  base::RunLoop loop3;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        ASSERT_EQ(usage.size(), 1u);
        EXPECT_EQ(usage[0]->origin, "https://example.com");
        EXPECT_EQ(usage[0]->usage_bytes, 1024);
        l->Quit();
      },
      &loop3));
  loop3.Run();
}

// 10. GetStorageUsage returns entries sorted alphabetically by origin.
TEST_F(OWLStorageServiceTest, StorageService_GetUsage_Sorted) {
  service_->AddStorageUsageForTesting("https://zoo.example.com", 100);
  service_->AddStorageUsageForTesting("https://alpha.example.com", 200);
  service_->AddStorageUsageForTesting("https://middle.example.com", 300);

  base::RunLoop loop;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        ASSERT_EQ(usage.size(), 3u);
        EXPECT_EQ(usage[0]->origin, "https://alpha.example.com");
        EXPECT_EQ(usage[0]->usage_bytes, 200);
        EXPECT_EQ(usage[1]->origin, "https://middle.example.com");
        EXPECT_EQ(usage[1]->usage_bytes, 300);
        EXPECT_EQ(usage[2]->origin, "https://zoo.example.com");
        EXPECT_EQ(usage[2]->usage_bytes, 100);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// 11. AddStorageUsageForTesting with same origin overwrites (not accumulates).
TEST_F(OWLStorageServiceTest, StorageService_AddUsage_OverwritesSameOrigin) {
  service_->AddStorageUsageForTesting("https://example.com", 1000);
  service_->AddStorageUsageForTesting("https://example.com", 2000);

  base::RunLoop loop;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        ASSERT_EQ(usage.size(), 1u);
        EXPECT_EQ(usage[0]->origin, "https://example.com");
        // Overwrite semantics: should be 2000, not 3000.
        EXPECT_EQ(usage[0]->usage_bytes, 2000);
        l->Quit();
      },
      &loop));
  loop.Run();
}

// 12. ClearBrowsingData time range is ignored in memory mode — all matching
// data is cleared regardless of start_time / end_time.
TEST_F(OWLStorageServiceTest, StorageService_ClearData_TimeRangeIgnored) {
  service_->AddCookieForTesting("old.com");
  service_->AddCookieForTesting("new.com");
  service_->AddStorageUsageForTesting("https://old.com", 512);
  service_->AddStorageUsageForTesting("https://new.com", 1024);

  // Pass a narrow time range. In-memory mode has no timestamps,
  // so this should still clear everything matching the type mask.
  base::RunLoop loop;
  remote_->ClearBrowsingData(
      OWLStorageService::kAllDataTypes, 1000.0, 2000.0,
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            EXPECT_TRUE(success);
            l->Quit();
          },
          &loop));
  loop.Run();

  // All cookies cleared despite time range.
  base::RunLoop loop2;
  remote_->GetCookieDomains(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::CookieDomainPtr> domains) {
        EXPECT_EQ(domains.size(), 0u);
        l->Quit();
      },
      &loop2));
  loop2.Run();

  // All storage usage cleared despite time range.
  base::RunLoop loop3;
  remote_->GetStorageUsage(base::BindOnce(
      [](base::RunLoop* l,
         std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
        EXPECT_EQ(usage.size(), 0u);
        l->Quit();
      },
      &loop3));
  loop3.Run();
}

}  // namespace
}  // namespace owl
