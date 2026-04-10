// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_history_service.h"

#include "base/files/scoped_temp_dir.h"
#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "base/time/time.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

class OWLHistoryServiceTest : public testing::Test {
 protected:
  void SetUp() override {
    service_ = std::make_unique<OWLHistoryService>();  // memory mode
    service_->WaitForInitializationForTesting();
  }

  void TearDown() override {
    if (service_) {
      service_->Shutdown();
    }
  }

  bool AddVisitSync(const std::string& url, const std::string& title) {
    bool result = false;
    base::RunLoop loop;
    service_->AddVisit(url, title,
        base::BindOnce([](bool* out, base::RunLoop* l, bool ok) {
          *out = ok; l->Quit();
        }, &result, &loop));
    loop.Run();
    return result;
  }

  std::vector<HistoryEntry> QueryByTimeSync(const std::string& q = "",
                                            int max = 100, int off = 0) {
    std::vector<HistoryEntry> out;
    base::RunLoop loop;
    service_->QueryByTime(q, max, off,
        base::BindOnce([](std::vector<HistoryEntry>* o, base::RunLoop* l,
                          std::vector<HistoryEntry> e, int) {
          *o = std::move(e); l->Quit();
        }, &out, &loop));
    loop.Run();
    return out;
  }

  std::vector<HistoryEntry> QueryByVisitCountSync(const std::string& q,
                                                  int max = 100) {
    std::vector<HistoryEntry> out;
    base::RunLoop loop;
    service_->QueryByVisitCount(q, max,
        base::BindOnce([](std::vector<HistoryEntry>* o, base::RunLoop* l,
                          std::vector<HistoryEntry> e) {
          *o = std::move(e); l->Quit();
        }, &out, &loop));
    loop.Run();
    return out;
  }

  base::test::SingleThreadTaskEnvironment task_environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
  std::unique_ptr<OWLHistoryService> service_;
};

// AC-001: AddVisit writes and is queryable (URL + title + time).
TEST_F(OWLHistoryServiceTest, AddVisitAndQuery) {
  ASSERT_TRUE(AddVisitSync("https://example.com", "Example"));
  auto entries = QueryByTimeSync();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].url, "https://example.com");
  EXPECT_EQ(entries[0].title, "Example");
  EXPECT_EQ(entries[0].visit_count, 1);
  EXPECT_FALSE(entries[0].last_visit_time.is_null());
}

// AC-001: Empty title is valid.
TEST_F(OWLHistoryServiceTest, AddVisitEmptyTitle) {
  ASSERT_TRUE(AddVisitSync("https://example.com", ""));
  ASSERT_EQ(QueryByTimeSync().size(), 1u);
  EXPECT_EQ(QueryByTimeSync()[0].title, "");
}

// Dedup: same URL within 30s only updates visit_count.
TEST_F(OWLHistoryServiceTest, DeduplicateWithin30s) {
  ASSERT_TRUE(AddVisitSync("https://dedup.com", "First"));
  ASSERT_TRUE(AddVisitSync("https://dedup.com", "Second"));
  auto entries = QueryByTimeSync();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].visit_count, 2);
  EXPECT_EQ(entries[0].title, "Second");
}

// Dedup: after 30s, dedup cache expires (UPSERT still merges same URL).
TEST_F(OWLHistoryServiceTest, NoDedupAfter30s) {
  ASSERT_TRUE(AddVisitSync("https://nd.com", "V1"));
  task_environment_.AdvanceClock(base::Seconds(31));
  ASSERT_TRUE(AddVisitSync("https://nd.com", "V2"));
  auto entries = QueryByTimeSync();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_GE(entries[0].visit_count, 2);
}

// QueryByTime: ordered by last_visit_time DESC.
TEST_F(OWLHistoryServiceTest, QueryByTimeOrdering) {
  ASSERT_TRUE(AddVisitSync("https://old.com", "Old"));
  task_environment_.AdvanceClock(base::Seconds(31));
  ASSERT_TRUE(AddVisitSync("https://new.com", "New"));
  auto entries = QueryByTimeSync();
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[0].url, "https://new.com");
  EXPECT_GE(entries[0].last_visit_time, entries[1].last_visit_time);
}

// QueryByVisitCount: ordered by visit_count DESC.
TEST_F(OWLHistoryServiceTest, QueryByVisitCountOrdering) {
  ASSERT_TRUE(AddVisitSync("https://rare.com", "Rare"));
  ASSERT_TRUE(AddVisitSync("https://freq.com", "Freq"));
  ASSERT_TRUE(AddVisitSync("https://freq.com", "Freq"));
  auto entries = QueryByVisitCountSync("");
  ASSERT_EQ(entries.size(), 2u);
  EXPECT_EQ(entries[0].url, "https://freq.com");
  EXPECT_GE(entries[0].visit_count, entries[1].visit_count);
}

// FTS5: search matches title.
TEST_F(OWLHistoryServiceTest, FtsSearchByTitle) {
  ASSERT_TRUE(AddVisitSync("https://a.com", "Chromium Browser"));
  ASSERT_TRUE(AddVisitSync("https://b.com", "Unrelated Page"));
  auto entries = QueryByTimeSync("Chromium");
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].title, "Chromium Browser");
}

// FTS5: search matches URL.
TEST_F(OWLHistoryServiceTest, FtsSearchByUrl) {
  ASSERT_TRUE(AddVisitSync("https://example.com/docs", "Docs"));
  ASSERT_TRUE(AddVisitSync("https://other.com", "Other"));
  auto entries = QueryByTimeSync("example");
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].url, "https://example.com/docs");
}

// FTS5: prefix search.
TEST_F(OWLHistoryServiceTest, FtsPrefixSearch) {
  ASSERT_TRUE(AddVisitSync("https://a.com", "Programming Guide"));
  auto entries = QueryByTimeSync("Prog");
  ASSERT_EQ(entries.size(), 1u);
}

// FTS5: no match returns empty.
TEST_F(OWLHistoryServiceTest, FtsNoMatch) {
  ASSERT_TRUE(AddVisitSync("https://a.com", "Hello"));
  EXPECT_TRUE(QueryByTimeSync("zzzzz").empty());
}

// Delete: removed entry no longer returned.
TEST_F(OWLHistoryServiceTest, DeleteSingle) {
  ASSERT_TRUE(AddVisitSync("https://del.com", "Del"));
  ASSERT_TRUE(AddVisitSync("https://keep.com", "Keep"));
  bool ok = false;
  base::RunLoop loop;
  service_->Delete("https://del.com",
      base::BindOnce([](bool* o, base::RunLoop* l, bool s) {
        *o = s; l->Quit();
      }, &ok, &loop));
  loop.Run();
  EXPECT_TRUE(ok);
  auto entries = QueryByTimeSync();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].url, "https://keep.com");
}

// Delete: non-existent URL does not crash.
TEST_F(OWLHistoryServiceTest, DeleteNonexistent) {
  base::RunLoop loop;
  service_->Delete("https://ghost.com",
      base::BindOnce([](base::RunLoop* l, bool) { l->Quit(); }, &loop));
  loop.Run();
}

// DeleteRange: deletes entries within [start, end).
TEST_F(OWLHistoryServiceTest, DeleteRange) {
  ASSERT_TRUE(AddVisitSync("https://old.com", "Old"));
  base::Time mid = base::Time::Now();
  task_environment_.AdvanceClock(base::Seconds(31));
  ASSERT_TRUE(AddVisitSync("https://new.com", "New"));
  int deleted = 0;
  base::RunLoop loop;
  service_->DeleteRange(base::Time(), mid + base::Seconds(1),
      base::BindOnce([](int* o, base::RunLoop* l, int c) {
        *o = c; l->Quit();
      }, &deleted, &loop));
  loop.Run();
  EXPECT_EQ(deleted, 1);
  auto entries = QueryByTimeSync();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].url, "https://new.com");
}

// DeleteRange: empty range deletes nothing.
TEST_F(OWLHistoryServiceTest, DeleteRangeEmpty) {
  int deleted = -1;
  base::RunLoop loop;
  service_->DeleteRange(base::Time(), base::Time::Now(),
      base::BindOnce([](int* o, base::RunLoop* l, int c) {
        *o = c; l->Quit();
      }, &deleted, &loop));
  loop.Run();
  EXPECT_EQ(deleted, 0);
}

// Clear: removes all records.
TEST_F(OWLHistoryServiceTest, ClearAll) {
  ASSERT_TRUE(AddVisitSync("https://a.com", "A"));
  ASSERT_TRUE(AddVisitSync("https://b.com", "B"));
  bool ok = false;
  base::RunLoop loop;
  service_->Clear(
      base::BindOnce([](bool* o, base::RunLoop* l, bool s) {
        *o = s; l->Quit();
      }, &ok, &loop));
  loop.Run();
  EXPECT_TRUE(ok);
  EXPECT_TRUE(QueryByTimeSync().empty());
}

// URL filtering: disallowed schemes.
TEST_F(OWLHistoryServiceTest, FilterAboutUrl) {
  EXPECT_FALSE(AddVisitSync("about:blank", ""));
  EXPECT_TRUE(QueryByTimeSync().empty());
}

TEST_F(OWLHistoryServiceTest, FilterChromeUrl) {
  EXPECT_FALSE(AddVisitSync("chrome://settings", ""));
}

TEST_F(OWLHistoryServiceTest, FilterFileUrl) {
  EXPECT_FALSE(AddVisitSync("file:///tmp/x.html", ""));
}

TEST_F(OWLHistoryServiceTest, FilterJavascriptUrl) {
  EXPECT_FALSE(AddVisitSync("javascript:alert(1)", ""));
}

TEST_F(OWLHistoryServiceTest, FilterDataUrl) {
  EXPECT_FALSE(AddVisitSync("data:text/html,hi", ""));
}

TEST_F(OWLHistoryServiceTest, FilterBlobUrl) {
  EXPECT_FALSE(AddVisitSync("blob:https://x.com/uuid", ""));
}

TEST_F(OWLHistoryServiceTest, FilterOwlUrl) {
  EXPECT_FALSE(AddVisitSync("owl://internal", ""));
}

// URL filtering: case-insensitive (GURL lowercases scheme).
TEST_F(OWLHistoryServiceTest, FilterCaseInsensitive) {
  EXPECT_FALSE(AddVisitSync("ABOUT:blank", ""));
}

// URL normalization: scheme+host lowercase.
TEST_F(OWLHistoryServiceTest, NormalizeUrlLowercase) {
  EXPECT_EQ(OWLHistoryService::NormalizeUrl("HTTP://EXAMPLE.COM/Path"),
            "http://example.com/Path");
}

// URL normalization: strip trailing slash.
TEST_F(OWLHistoryServiceTest, NormalizeUrlStripTrailingSlash) {
  EXPECT_EQ(OWLHistoryService::NormalizeUrl("https://example.com/"),
            "https://example.com");
}

// URL normalization: preserve query/fragment.
TEST_F(OWLHistoryServiceTest, NormalizeUrlPreserveQuery) {
  auto r = OWLHistoryService::NormalizeUrl("https://example.com/?q=1");
  EXPECT_NE(r.find("?q=1"), std::string::npos);
}

// URL normalization: invalid URL passed through.
TEST_F(OWLHistoryServiceTest, NormalizeUrlInvalid) {
  EXPECT_EQ(OWLHistoryService::NormalizeUrl("not a url"), "not a url");
}

// Schema: fresh DB is usable (version management).
class OWLHistoryServiceSchemaTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    db_path_ = temp_dir_.GetPath().AppendASCII("history.db");
  }
  base::test::SingleThreadTaskEnvironment task_environment_;
  base::ScopedTempDir temp_dir_;
  base::FilePath db_path_;
};

TEST_F(OWLHistoryServiceSchemaTest, NewDbUsable) {
  auto svc = std::make_unique<OWLHistoryService>(db_path_);
  svc->WaitForInitializationForTesting();
  bool ok = false;
  base::RunLoop loop;
  svc->AddVisit("https://schema.com", "Schema",
      base::BindOnce([](bool* o, base::RunLoop* l, bool s) {
        *o = s; l->Quit();
      }, &ok, &loop));
  loop.Run();
  EXPECT_TRUE(ok);
  svc->Shutdown();
}

// AC-008: Persistence survives destroy + recreate.
class OWLHistoryServicePersistTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    db_path_ = temp_dir_.GetPath().AppendASCII("history.db");
    service_ = std::make_unique<OWLHistoryService>(db_path_);
    service_->WaitForInitializationForTesting();
  }

  void TearDown() override {
    if (service_) {
      service_->Shutdown();
    }
  }

  void RecreateService() {
    service_->Shutdown();
    service_.reset();
    service_ = std::make_unique<OWLHistoryService>(db_path_);
    service_->WaitForInitializationForTesting();
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  base::ScopedTempDir temp_dir_;
  base::FilePath db_path_;
  std::unique_ptr<OWLHistoryService> service_;
};

// AC-008: Data survives destroy + recreate.
TEST_F(OWLHistoryServicePersistTest, DataSurvivesRestart) {
  bool ok = false;
  {
    base::RunLoop loop;
    service_->AddVisit("https://persist.com", "Persist",
        base::BindOnce([](bool* o, base::RunLoop* l, bool s) {
          *o = s; l->Quit();
        }, &ok, &loop));
    loop.Run();
  }
  ASSERT_TRUE(ok);

  RecreateService();

  std::vector<HistoryEntry> entries;
  base::RunLoop loop;
  service_->QueryByTime("", 100, 0,
      base::BindOnce([](std::vector<HistoryEntry>* o, base::RunLoop* l,
                        std::vector<HistoryEntry> e, int) {
        *o = std::move(e); l->Quit();
      }, &entries, &loop));
  loop.Run();
  ASSERT_EQ(entries.size(), 1u);
  EXPECT_EQ(entries[0].url, "https://persist.com");
  EXPECT_EQ(entries[0].title, "Persist");
}

// Pagination: offset skips entries.
TEST_F(OWLHistoryServiceTest, PaginationWithOffset) {
  for (int i = 0; i < 5; ++i) {
    ASSERT_TRUE(AddVisitSync(
        "https://p" + std::to_string(i) + ".com", "P" + std::to_string(i)));
    task_environment_.AdvanceClock(base::Seconds(31));
  }
  auto page1 = QueryByTimeSync("", 2, 0);
  auto page2 = QueryByTimeSync("", 2, 2);
  ASSERT_EQ(page1.size(), 2u);
  ASSERT_EQ(page2.size(), 2u);
  EXPECT_NE(page1[0].url, page2[0].url);
}

}  // namespace
}  // namespace owl
