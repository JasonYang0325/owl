// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_bookmark_service.h"

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/mojom/bookmarks.mojom.h"

namespace owl {
namespace {

class OWLBookmarkServiceTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool init = [] { mojo::core::Init(); return true; }();
    (void)init;
  }

  void SetUp() override {
    service_ = std::make_unique<OWLBookmarkService>();
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBookmarkService> service_;
  mojo::Remote<owl::mojom::BookmarkService> remote_;
};

TEST_F(OWLBookmarkServiceTest, InitiallyEmpty) {
  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 0u);
        l->Quit();
      }, &loop));
  loop.Run();
}

TEST_F(OWLBookmarkServiceTest, AddBookmark) {
  base::RunLoop loop;
  remote_->Add("Test", "https://example.com", std::nullopt,
      base::BindOnce(
          [](base::RunLoop* l, owl::mojom::BookmarkItemPtr item) {
            ASSERT_FALSE(item.is_null());
            EXPECT_EQ(item->title, "Test");
            EXPECT_EQ(item->url, "https://example.com");
            EXPECT_FALSE(item->id.empty());
            l->Quit();
          }, &loop));
  loop.Run();
  EXPECT_EQ(service_->count(), 1u);
}

TEST_F(OWLBookmarkServiceTest, AddEmptyTitleFails) {
  base::RunLoop loop;
  remote_->Add("", "https://example.com", std::nullopt,
      base::BindOnce(
          [](base::RunLoop* l, owl::mojom::BookmarkItemPtr item) {
            EXPECT_TRUE(item.is_null());
            l->Quit();
          }, &loop));
  loop.Run();
}

TEST_F(OWLBookmarkServiceTest, RemoveBookmark) {
  // Add first.
  std::string id;
  {
    base::RunLoop loop;
    remote_->Add("Test", "https://example.com", std::nullopt,
        base::BindOnce(
            [](std::string* out, base::RunLoop* l,
               owl::mojom::BookmarkItemPtr item) {
              *out = item->id;
              l->Quit();
            }, &id, &loop));
    loop.Run();
  }

  // Remove.
  base::RunLoop loop;
  remote_->Remove(id, base::BindOnce(
      [](base::RunLoop* l, bool success) {
        EXPECT_TRUE(success);
        l->Quit();
      }, &loop));
  loop.Run();
  EXPECT_EQ(service_->count(), 0u);
}

TEST_F(OWLBookmarkServiceTest, RemoveNonexistentFails) {
  base::RunLoop loop;
  remote_->Remove("nonexistent", base::BindOnce(
      [](base::RunLoop* l, bool success) {
        EXPECT_FALSE(success);
        l->Quit();
      }, &loop));
  loop.Run();
}

TEST_F(OWLBookmarkServiceTest, UpdateBookmark) {
  std::string id;
  {
    base::RunLoop loop;
    remote_->Add("Old", "https://old.com", std::nullopt,
        base::BindOnce(
            [](std::string* out, base::RunLoop* l,
               owl::mojom::BookmarkItemPtr item) {
              *out = item->id;
              l->Quit();
            }, &id, &loop));
    loop.Run();
  }

  {
    base::RunLoop loop;
    remote_->Update(id, "New Title", std::nullopt,
        base::BindOnce(
            [](base::RunLoop* l, bool success) {
              EXPECT_TRUE(success);
              l->Quit();
            }, &loop));
    loop.Run();
  }

  // Verify.
  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        ASSERT_EQ(items.size(), 1u);
        EXPECT_EQ(items[0]->title, "New Title");
        EXPECT_EQ(items[0]->url, "https://old.com");
        l->Quit();
      }, &loop));
  loop.Run();
}

TEST_F(OWLBookmarkServiceTest, GetAllReturnsMultiple) {
  for (int i = 0; i < 3; ++i) {
    base::RunLoop loop;
    remote_->Add("BM" + std::to_string(i), "https://ex.com/" + std::to_string(i),
        std::nullopt,
        base::BindOnce([](base::RunLoop* l, owl::mojom::BookmarkItemPtr) {
          l->Quit();
        }, &loop));
    loop.Run();
  }

  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 3u);
        l->Quit();
      }, &loop));
  loop.Run();
}

// =============================================================================
// Phase 35: Persistence tests (AC-005, AC-006)
// =============================================================================

class OWLBookmarkServicePersistTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool init = [] { mojo::core::Init(); return true; }();
    (void)init;
  }

  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    storage_path_ = temp_dir_.GetPath().AppendASCII("bookmarks.json");
    service_ = std::make_unique<OWLBookmarkService>(storage_path_);
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  void ResetServiceWithSamePath() {
    remote_.reset();
    service_.reset();
    service_ = std::make_unique<OWLBookmarkService>(storage_path_);
    service_->Bind(remote_.BindNewPipeAndPassReceiver());
  }

  // Helper: Add a bookmark and return its ID.
  std::string AddBookmark(const std::string& title, const std::string& url) {
    std::string id;
    base::RunLoop loop;
    remote_->Add(title, url, std::nullopt,
        base::BindOnce(
            [](std::string* out, base::RunLoop* l,
               owl::mojom::BookmarkItemPtr item) {
              ASSERT_FALSE(item.is_null());
              *out = item->id;
              l->Quit();
            }, &id, &loop));
    loop.Run();
    return id;
  }

  // TaskEnvironment with ThreadPool (needed for SequencedTaskRunner in persist).
  base::test::TaskEnvironment task_environment_;
  base::ScopedTempDir temp_dir_;
  base::FilePath storage_path_;
  std::unique_ptr<OWLBookmarkService> service_;
  mojo::Remote<owl::mojom::BookmarkService> remote_;
};

// AC-005, AC-006: Add bookmarks, persist, reload from same path, verify data.
TEST_F(OWLBookmarkServicePersistTest, PersistAndReload) {
  AddBookmark("Site A", "https://a.com");
  AddBookmark("Site B", "https://b.com");
  ASSERT_EQ(service_->count(), 2u);

  service_->PersistNow();
  task_environment_.RunUntilIdle();  // Flush ThreadPool file I/O.

  // Create a fresh service from the same storage path.
  // Bind() already calls LoadFromFile(), so no explicit call needed.
  ResetServiceWithSamePath();

  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 2u);
        // Verify both bookmarks survived round-trip.
        bool found_a = false, found_b = false;
        for (auto& item : items) {
          if (item->title == "Site A" && item->url == "https://a.com")
            found_a = true;
          if (item->title == "Site B" && item->url == "https://b.com")
            found_b = true;
        }
        EXPECT_TRUE(found_a);
        EXPECT_TRUE(found_b);
        l->Quit();
      }, &loop));
  loop.Run();
}

// AC-005, AC-006: LoadFromFile on an empty file → GetAll returns empty.
TEST_F(OWLBookmarkServicePersistTest, LoadFromEmptyFile) {
  base::WriteFile(storage_path_, "");

  // Bind() already calls LoadFromFile(), so no explicit call needed.
  ResetServiceWithSamePath();

  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 0u);
        l->Quit();
      }, &loop));
  loop.Run();
}

// AC-005, AC-006: LoadFromFile on corrupted (non-JSON) file → no crash, empty.
TEST_F(OWLBookmarkServicePersistTest, LoadFromCorruptedFile) {
  base::WriteFile(storage_path_, "this is not json {{{}}}}");

  // Bind() already calls LoadFromFile(), so no explicit call needed.
  ResetServiceWithSamePath();

  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 0u);
        l->Quit();
      }, &loop));
  loop.Run();
}

// AC-005, AC-006: JSON array with entry missing required "title" → skipped.
TEST_F(OWLBookmarkServicePersistTest, LoadFromMissingFieldsFile) {
  // Entry missing "title" should be skipped; valid entry should load.
  const char* json = R"({"version":1,"bookmarks":[
    {"id":"1","url":"https://notitle.com"},
    {"id":"2","title":"Valid","url":"https://valid.com"}
  ],"next_id":3})";
  base::WriteFile(storage_path_, json);

  // Bind() already calls LoadFromFile(), so no explicit call needed.
  ResetServiceWithSamePath();

  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 1u);
        if (items.size() == 1u) {
          EXPECT_EQ(items[0]->title, "Valid");
          EXPECT_EQ(items[0]->url, "https://valid.com");
        }
        l->Quit();
      }, &loop));
  loop.Run();
}

// AC-005, AC-006: After reload, new IDs must not collide with persisted IDs.
TEST_F(OWLBookmarkServicePersistTest, NextIdSurvivesReload) {
  std::string old_id = AddBookmark("First", "https://first.com");
  service_->PersistNow();
  task_environment_.RunUntilIdle();  // Flush ThreadPool file I/O.

  // Reload. Bind() already calls LoadFromFile().
  ResetServiceWithSamePath();

  // Add another bookmark after reload.
  std::string new_id;
  {
    base::RunLoop loop;
    remote_->Add("Second", "https://second.com", std::nullopt,
        base::BindOnce(
            [](std::string* out, base::RunLoop* l,
               owl::mojom::BookmarkItemPtr item) {
              ASSERT_FALSE(item.is_null());
              *out = item->id;
              l->Quit();
            }, &new_id, &loop));
    loop.Run();
  }

  EXPECT_NE(old_id, new_id) << "New ID must not collide with reloaded ID";
}

// =============================================================================
// Phase 35: Input validation tests (AC-001)
// =============================================================================

// AC-001: javascript: URL must be rejected.
TEST_F(OWLBookmarkServiceTest, AddRejectsJavascriptUrl) {
  base::RunLoop loop;
  remote_->Add("XSS", "javascript:alert(1)", std::nullopt,
      base::BindOnce(
          [](base::RunLoop* l, owl::mojom::BookmarkItemPtr item) {
            EXPECT_TRUE(item.is_null());
            l->Quit();
          }, &loop));
  loop.Run();
  EXPECT_EQ(service_->count(), 0u);
}

// AC-001: Empty URL must be rejected.
TEST_F(OWLBookmarkServiceTest, AddRejectsEmptyUrl) {
  base::RunLoop loop;
  remote_->Add("NoURL", "", std::nullopt,
      base::BindOnce(
          [](base::RunLoop* l, owl::mojom::BookmarkItemPtr item) {
            EXPECT_TRUE(item.is_null());
            l->Quit();
          }, &loop));
  loop.Run();
  EXPECT_EQ(service_->count(), 0u);
}

// AC-001: Title longer than 1024 characters must be rejected.
TEST_F(OWLBookmarkServiceTest, AddRejectsTooLongTitle) {
  std::string long_title(1025, 'A');
  base::RunLoop loop;
  remote_->Add(long_title, "https://example.com", std::nullopt,
      base::BindOnce(
          [](base::RunLoop* l, owl::mojom::BookmarkItemPtr item) {
            EXPECT_TRUE(item.is_null());
            l->Quit();
          }, &loop));
  loop.Run();
  EXPECT_EQ(service_->count(), 0u);
}

// AC-001: Update with javascript: URL must be rejected.
TEST_F(OWLBookmarkServiceTest, UpdateRejectsJavascriptUrl) {
  std::string id;
  {
    base::RunLoop loop;
    remote_->Add("Safe", "https://safe.com", std::nullopt,
        base::BindOnce(
            [](std::string* out, base::RunLoop* l,
               owl::mojom::BookmarkItemPtr item) {
              *out = item->id;
              l->Quit();
            }, &id, &loop));
    loop.Run();
  }

  base::RunLoop loop;
  remote_->Update(id, std::nullopt, "javascript:alert(1)",
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            EXPECT_FALSE(success);
            l->Quit();
          }, &loop));
  loop.Run();

  // Verify the original URL was not changed.
  {
    base::RunLoop verify_loop;
    remote_->GetAll(base::BindOnce(
        [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
          ASSERT_EQ(items.size(), 1u);
          EXPECT_EQ(items[0]->url, "https://safe.com");
          l->Quit();
        }, &verify_loop));
    verify_loop.Run();
  }
}

// AC-005: File containing javascript: URL entries -- skipped on load.
TEST_F(OWLBookmarkServicePersistTest, LoadFromFileSkipsInvalidUrls) {
  const char* json = R"json({"version":1,"bookmarks":[
    {"id":"1","title":"Evil","url":"javascript:alert(1)"},
    {"id":"2","title":"Good","url":"https://good.com"}
  ],"next_id":3})json";
  base::WriteFile(storage_path_, json);

  // Bind() already calls LoadFromFile(), so no explicit call needed.
  ResetServiceWithSamePath();

  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        EXPECT_EQ(items.size(), 1u);
        if (items.size() == 1u) {
          EXPECT_EQ(items[0]->title, "Good");
          EXPECT_EQ(items[0]->url, "https://good.com");
        }
        l->Quit();
      }, &loop));
  loop.Run();
}

// =============================================================================
// Phase 35 review: Update edge-case tests (P1-8)
// =============================================================================

// P1-8: Update with a nonexistent ID should return false.
TEST_F(OWLBookmarkServiceTest, UpdateNonexistentFails) {
  base::RunLoop loop;
  remote_->Update("nonexistent-id-999", "New Title", std::nullopt,
      base::BindOnce(
          [](base::RunLoop* l, bool success) {
            EXPECT_FALSE(success);
            l->Quit();
          }, &loop));
  loop.Run();
}

// P1-8: Update with an empty title should be rejected; original title preserved.
TEST_F(OWLBookmarkServiceTest, UpdateRejectsEmptyTitle) {
  std::string id;
  {
    base::RunLoop loop;
    remote_->Add("Original", "https://example.com", std::nullopt,
        base::BindOnce(
            [](std::string* out, base::RunLoop* l,
               owl::mojom::BookmarkItemPtr item) {
              ASSERT_FALSE(item.is_null());
              *out = item->id;
              l->Quit();
            }, &id, &loop));
    loop.Run();
  }

  // Attempt to update with empty title — should fail.
  {
    base::RunLoop loop;
    remote_->Update(id, "", std::nullopt,
        base::BindOnce(
            [](base::RunLoop* l, bool success) {
              EXPECT_FALSE(success);
              l->Quit();
            }, &loop));
    loop.Run();
  }

  // Verify original title is preserved.
  base::RunLoop loop;
  remote_->GetAll(base::BindOnce(
      [](base::RunLoop* l, std::vector<owl::mojom::BookmarkItemPtr> items) {
        ASSERT_EQ(items.size(), 1u);
        EXPECT_EQ(items[0]->title, "Original");
        l->Quit();
      }, &loop));
  loop.Run();
}

}  // namespace
}  // namespace owl
