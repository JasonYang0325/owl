// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_HOST_OWL_HISTORY_SERVICE_H_
#define THIRD_PARTY_OWL_HOST_OWL_HISTORY_SERVICE_H_

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/sequence_checker.h"
#include "base/task/single_thread_task_runner.h"
#include "base/threading/thread.h"
#include "base/time/time.h"

class GURL;

namespace sql {
class Database;
}

namespace base {
class WaitableEvent;
}

namespace owl {

struct HistoryEntry {
  int64_t id = 0;
  std::string url;
  std::string title;
  base::Time visit_time;
  base::Time last_visit_time;
  int visit_count = 0;
};

// SQLite-backed history service with substring search over URL/title.
// Public API runs on the UI thread; SQLite I/O is posted to a dedicated
// single DB thread. If |db_path| is empty, operates in :memory: mode.
//
// Shutdown() must be called before destruction to flush WAL and destroy the
// database handle on the DB thread.
class OWLHistoryService {
 public:
  // Memory-only mode (no persistence). Used by tests and off-the-record.
  OWLHistoryService();
  // |db_path|: path to history.db. Empty = memory-only mode.
  explicit OWLHistoryService(const base::FilePath& db_path);
  ~OWLHistoryService();

  OWLHistoryService(const OWLHistoryService&) = delete;
  OWLHistoryService& operator=(const OWLHistoryService&) = delete;

  // Synchronously waits for pending DB operations and WAL checkpoint.
  // Must be called before destruction (e.g., in BrowserContext::Destroy).
  void Shutdown();

  // Blocks until all previously posted DB tasks, including initialization,
  // complete. Intended for unit tests.
  void WaitForInitializationForTesting();

  // Add a visit. Automatically normalizes, filters, and deduplicates.
  using AddVisitCallback = base::OnceCallback<void(bool success)>;
  void AddVisit(const std::string& url,
                const std::string& title,
                AddVisitCallback callback);

  // Query by time (history list + search). Results ordered by
  // last_visit_time DESC. |total| is the total count for pagination.
  using QueryCallback =
      base::OnceCallback<void(std::vector<HistoryEntry> entries, int total)>;
  void QueryByTime(const std::string& search_query,
                   int max_results,
                   int offset,
                   QueryCallback callback);

  // Query by visit count (address bar completion). Results ordered by
  // visit_count DESC. No total count (top-N only, no pagination).
  using QueryEntriesCallback =
      base::OnceCallback<void(std::vector<HistoryEntry> entries)>;
  void QueryByVisitCount(const std::string& search_query,
                         int max_results,
                         QueryEntriesCallback callback);

  // Delete a single URL.
  using BoolCallback = base::OnceCallback<void(bool success)>;
  void Delete(const std::string& url, BoolCallback callback);

  // Delete all visits in [start, end) based on last_visit_time.
  using IntCallback = base::OnceCallback<void(int deleted_count)>;
  void DeleteRange(base::Time start, base::Time end, IntCallback callback);

  // Delete all history.
  void Clear(BoolCallback callback);

  // Set a callback to be notified when history changes (a visit is added).
  using HistoryChangeCallback = base::RepeatingCallback<void(const std::string& url)>;
  void SetChangeCallback(HistoryChangeCallback callback);

  // URL utilities (public for testing).
  static std::string NormalizeUrl(const std::string& url);
  static bool IsUrlAllowed(const GURL& gurl);
  static bool IsUrlAllowed(const std::string& url);

 private:
  static constexpr int kCurrentSchemaVersion = 1;
  static constexpr size_t kMaxUrlLength = 2048;
  static constexpr base::TimeDelta kDedupeWindow = base::Seconds(30);
  static constexpr size_t kMaxCacheSize = 1000;

  void StartDbThread();

  // DB thread operations.
  void InitOnDbThread();
  void ShutdownOnDbThread(base::WaitableEvent* done);
  bool CreateSchemaV1(sql::Database* db);
  bool EnsureSearchSchemaObjects(sql::Database* db);
  void AddVisitOnDbThread(std::string url,
                          std::string title,
                          bool skip_insert,
                          AddVisitCallback callback);
  void QueryByTimeOnDbThread(std::string query,
                             int max,
                             int offset,
                             QueryCallback callback);
  void QueryByVisitCountOnDbThread(std::string query,
                                   int max,
                                   QueryEntriesCallback callback);
  void DeleteOnDbThread(std::string url, BoolCallback callback);
  void DeleteRangeOnDbThread(base::Time start,
                             base::Time end,
                             IntCallback callback);
  void ClearOnDbThread(BoolCallback callback);

  // Build a safe SQLite LIKE pattern from user input.
  static std::string BuildLikePattern(const std::string& input);

  // Clean expired entries from the dedupe cache.
  void CleanExpiredCacheEntries(base::TimeTicks now);

  HistoryChangeCallback change_callback_;

  base::FilePath db_path_;
  std::unique_ptr<sql::Database> db_;
  base::Thread db_thread_;
  scoped_refptr<base::SingleThreadTaskRunner> db_task_runner_;
  bool is_shutdown_ = false;

  SEQUENCE_CHECKER(ui_sequence_checker_);
  SEQUENCE_CHECKER(db_sequence_checker_);

  // Dedupe cache: url -> last_visit_timestamp (UI thread only).
  std::unordered_map<std::string, base::TimeTicks> recent_visits_;
  base::TimeTicks last_cache_clean_time_;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_HISTORY_SERVICE_H_
