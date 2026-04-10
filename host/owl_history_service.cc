// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_history_service.h"

#include <algorithm>
#include <tuple>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/bind_post_task.h"
#include "base/synchronization/waitable_event.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "sql/transaction.h"
#include "url/gurl.h"

namespace owl {

namespace {

sql::DatabaseOptions MakeHistoryDbOptions(bool persistent) {
  sql::DatabaseOptions options;
  options.set_enable_triggers(true);
  if (persistent) {
    options.set_wal_mode(true);
  }
  return options;
}

int64_t TimeToUs(base::Time t) {
  return t.InMillisecondsSinceUnixEpoch() * 1000;
}

base::Time UsToTime(int64_t us) {
  return base::Time::FromMillisecondsSinceUnixEpoch(us / 1000);
}

int GetUserVersion(sql::Database* db) {
  sql::Statement s(db->GetUniqueStatement("PRAGMA user_version"));
  return s.Step() ? s.ColumnInt(0) : 0;
}

void SetUserVersion(sql::Database* db, int version) {
  std::string pragma = "PRAGMA user_version = " + base::NumberToString(version);
  std::ignore = db->Execute(base::cstring_view(pragma.c_str()));
}

HistoryEntry RowToEntry(sql::Statement* s) {
  HistoryEntry entry;
  entry.id = s->ColumnInt64(0);
  entry.url = s->ColumnString(1);
  entry.title = s->ColumnString(2);
  entry.visit_time = UsToTime(s->ColumnInt64(3));
  entry.last_visit_time = UsToTime(s->ColumnInt64(4));
  entry.visit_count = s->ColumnInt(5);
  return entry;
}

}  // namespace

OWLHistoryService::OWLHistoryService() : db_thread_("OWLHistoryServiceDB") {
  StartDbThread();
}

OWLHistoryService::OWLHistoryService(const base::FilePath& db_path)
    : db_path_(db_path), db_thread_("OWLHistoryServiceDB") {
  StartDbThread();
}

OWLHistoryService::~OWLHistoryService() {
  DCHECK(is_shutdown_) << "Shutdown() must be called before destruction";
}

void OWLHistoryService::StartDbThread() {
  DETACH_FROM_SEQUENCE(ui_sequence_checker_);
  DETACH_FROM_SEQUENCE(db_sequence_checker_);
  if (!db_thread_.Start()) {
    LOG(ERROR) << "[OWL] Failed to start history DB thread";
    return;
  }

  db_task_runner_ = db_thread_.task_runner();
  db_task_runner_->PostTask(
      FROM_HERE, base::BindOnce(&OWLHistoryService::InitOnDbThread,
                                base::Unretained(this)));
}

void OWLHistoryService::Shutdown() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_) {
    return;
  }
  is_shutdown_ = true;
  recent_visits_.clear();

  if (!db_task_runner_) {
    return;
  }

  base::WaitableEvent done;
  if (db_task_runner_->PostTask(
          FROM_HERE, base::BindOnce(&OWLHistoryService::ShutdownOnDbThread,
                                    base::Unretained(this), &done))) {
    done.Wait();
  }

  db_thread_.Stop();
  db_task_runner_.reset();
}

void OWLHistoryService::WaitForInitializationForTesting() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (!db_task_runner_) {
    return;
  }

  base::WaitableEvent done;
  if (db_task_runner_->PostTask(
          FROM_HERE,
          base::BindOnce(
              [](base::WaitableEvent* event) { event->Signal(); }, &done))) {
    done.Wait();
  }
}

void OWLHistoryService::InitOnDbThread() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  auto options = MakeHistoryDbOptions(!db_path_.empty());
  db_.reset(new sql::Database(options, "OwlHistory"));

  bool opened = false;
  if (db_path_.empty()) {
    opened = db_->OpenInMemory();
  } else {
    opened = db_->Open(db_path_);
  }

  if (!opened) {
    LOG(ERROR) << "[OWL] Failed to open history DB";
    db_.reset();
    return;
  }

  int version = GetUserVersion(db_.get());
  if (version == 0) {
    if (!CreateSchemaV1(db_.get())) {
      LOG(ERROR) << "[OWL] Failed to create history schema";
      db_.reset();
      return;
    }
  } else if (version == kCurrentSchemaVersion) {
    // OK, current version.
  } else if (version > kCurrentSchemaVersion) {
    LOG(WARNING) << "[OWL] History DB version " << version << " > current "
                 << kCurrentSchemaVersion << ", rebuilding";
    db_->Raze();
    if (!CreateSchemaV1(db_.get())) {
      LOG(ERROR) << "[OWL] Failed to recreate history schema";
      db_.reset();
      return;
    }
  }

  if (!EnsureSearchSchemaObjects(db_.get())) {
    LOG(ERROR) << "[OWL] Failed to create search schema objects";
    db_.reset();
  }
}

void OWLHistoryService::ShutdownOnDbThread(base::WaitableEvent* done) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);

  if (db_) {
    std::ignore = db_->CheckpointDatabase();
    db_->Close();
    db_.reset();
  }

  done->Signal();
}

bool OWLHistoryService::CreateSchemaV1(sql::Database* db) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  sql::Transaction transaction(db);
  if (!transaction.Begin()) {
    return false;
  }

  static constexpr char kCreateVisits[] =
      "CREATE TABLE IF NOT EXISTS visits ("
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
      "  url TEXT NOT NULL,"
      "  title TEXT NOT NULL DEFAULT '',"
      "  visit_time INTEGER NOT NULL,"
      "  last_visit_time INTEGER NOT NULL,"
      "  visit_count INTEGER NOT NULL DEFAULT 1"
      ")";

  static constexpr char kCreateUrlIndex[] =
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_visits_url ON visits(url)";

  static constexpr char kCreateTimeIndex[] =
      "CREATE INDEX IF NOT EXISTS idx_visits_time "
      "ON visits(last_visit_time DESC)";

  if (!db->Execute(kCreateVisits) || !db->Execute(kCreateUrlIndex) ||
      !db->Execute(kCreateTimeIndex)) {
    return false;
  }

  SetUserVersion(db, kCurrentSchemaVersion);
  return transaction.Commit();
}

bool OWLHistoryService::EnsureSearchSchemaObjects(sql::Database* db) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  sql::Transaction transaction(db);
  if (!transaction.Begin()) {
    return false;
  }

  const auto execute = [db](base::cstring_view sql) {
    if (db->Execute(sql)) {
      return true;
    }
    LOG(ERROR) << "[OWL] Search schema SQL failed: " << sql
               << " error=" << db->GetErrorMessage();
    return false;
  };

  static constexpr char kCreateSearchTable[] =
      "CREATE TABLE IF NOT EXISTS visits_search ("
      "  visit_id INTEGER PRIMARY KEY,"
      "  url TEXT NOT NULL,"
      "  title TEXT NOT NULL"
      ")";

  static constexpr char kTriggerInsert[] =
      "CREATE TRIGGER IF NOT EXISTS visits_ai AFTER INSERT ON visits BEGIN"
      "  INSERT INTO visits_search(visit_id, url, title)"
      "  VALUES (new.id, lower(new.url), lower(new.title));"
      "END";

  static constexpr char kTriggerDelete[] =
      "CREATE TRIGGER IF NOT EXISTS visits_ad AFTER DELETE ON visits BEGIN"
      "  DELETE FROM visits_search WHERE visit_id = old.id;"
      "END";

  static constexpr char kTriggerUpdate[] =
      "CREATE TRIGGER IF NOT EXISTS visits_au AFTER UPDATE ON visits BEGIN"
      "  INSERT OR REPLACE INTO visits_search(visit_id, url, title)"
      "  VALUES (new.id, lower(new.url), lower(new.title));"
      "END";

  static constexpr char kDeleteStaleRows[] =
      "DELETE FROM visits_search "
      "WHERE visit_id NOT IN (SELECT id FROM visits)";

  static constexpr char kBackfillSearchTable[] =
      "INSERT OR REPLACE INTO visits_search(visit_id, url, title) "
      "SELECT id, lower(url), lower(title) FROM visits";

  if (!execute(kCreateSearchTable) || !execute(kTriggerInsert) ||
      !execute(kTriggerDelete) || !execute(kTriggerUpdate) ||
      !execute(kDeleteStaleRows) || !execute(kBackfillSearchTable)) {
    return false;
  }

  return transaction.Commit();
}

// static
std::string OWLHistoryService::NormalizeUrl(const std::string& url) {
  GURL parsed(url);
  if (!parsed.is_valid()) {
    return url;
  }

  GURL::Replacements replacements;
  std::string lower_scheme = base::ToLowerASCII(parsed.scheme());
  std::string lower_host = base::ToLowerASCII(parsed.host());
  replacements.SetSchemeStr(lower_scheme);
  replacements.SetHostStr(lower_host);
  GURL normalized = parsed.ReplaceComponents(replacements);
  std::string result = normalized.spec();

  // Strip trailing slash when path is "/" and no query/fragment.
  if (result.ends_with("/") && !parsed.has_query() && !parsed.has_ref() &&
      parsed.path() == "/") {
    result = result.substr(0, result.size() - 1);
  }
  return result;
}

// static
bool OWLHistoryService::IsUrlAllowed(const GURL& gurl) {
  if (!gurl.is_valid()) {
    return false;
  }
  auto scheme = std::string(gurl.scheme());
  return scheme != "about" && scheme != "chrome" && scheme != "owl" &&
         scheme != "data" && scheme != "blob" && scheme != "javascript" &&
         scheme != "file";
}

// static
bool OWLHistoryService::IsUrlAllowed(const std::string& url) {
  return IsUrlAllowed(GURL(url));
}

// static
std::string OWLHistoryService::BuildLikePattern(const std::string& input) {
  std::string trimmed(base::TrimWhitespaceASCII(input, base::TRIM_ALL));
  if (trimmed.empty()) {
    return std::string();
  }

  std::string escaped;
  escaped.reserve(trimmed.size());
  for (char c : trimmed) {
    if (c == '%' || c == '_' || c == '\\') {
      escaped.push_back('\\');
    }
    escaped.push_back(c);
  }

  return "%" + escaped + "%";
}

void OWLHistoryService::CleanExpiredCacheEntries(base::TimeTicks now) {
  // Throttle: only clean once per dedupe window.
  if (!last_cache_clean_time_.is_null() &&
      (now - last_cache_clean_time_) < kDedupeWindow) {
    return;
  }
  last_cache_clean_time_ = now;

  for (auto it = recent_visits_.begin(); it != recent_visits_.end();) {
    if ((now - it->second) > kDedupeWindow) {
      it = recent_visits_.erase(it);
    } else {
      ++it;
    }
  }

  // If still over limit, sort once and trim oldest in O(n log n).
  if (recent_visits_.size() > kMaxCacheSize) {
    std::vector<std::pair<std::string, base::TimeTicks>> entries(
        recent_visits_.begin(), recent_visits_.end());
    std::sort(entries.begin(), entries.end(),
              [](const auto& a, const auto& b) {
                return a.second > b.second;  // newest first
              });
    recent_visits_.clear();
    for (size_t i = 0; i < kMaxCacheSize && i < entries.size(); ++i) {
      recent_visits_.emplace(std::move(entries[i]));
    }
  }
}

void OWLHistoryService::SetChangeCallback(HistoryChangeCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  change_callback_ = std::move(callback);
}

void OWLHistoryService::AddVisit(const std::string& url,
                                 const std::string& title,
                                 AddVisitCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_ || !db_task_runner_) {
    std::move(callback).Run(false);
    return;
  }

  if (!IsUrlAllowed(url)) {
    std::move(callback).Run(false);
    return;
  }

  std::string normalized = NormalizeUrl(url);
  if (normalized.size() > kMaxUrlLength) {
    LOG(INFO) << "[OWL] Truncating URL from " << normalized.size()
              << " to " << kMaxUrlLength << " chars";
    normalized = normalized.substr(0, kMaxUrlLength);
  }

  base::TimeTicks now = base::TimeTicks::Now();
  CleanExpiredCacheEntries(now);

  // Skip INSERT if same URL was visited within the dedupe window.
  bool skip_insert = false;
  auto it = recent_visits_.find(normalized);
  if (it != recent_visits_.end() && (now - it->second) < kDedupeWindow) {
    skip_insert = true;
  }
  recent_visits_[normalized] = now;

  // Wrap the callback to fire change_callback_ on success.
  auto wrapped_callback = base::BindOnce(
      [](HistoryChangeCallback change_cb, std::string url,
         AddVisitCallback original_cb, bool success) {
        if (success && change_cb) {
          change_cb.Run(url);
        }
        std::move(original_cb).Run(success);
      },
      change_callback_, normalized, std::move(callback));

  auto ui_runner = base::SequencedTaskRunner::GetCurrentDefault();
  db_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&OWLHistoryService::AddVisitOnDbThread,
                     base::Unretained(this), normalized, title, skip_insert,
                     base::BindPostTask(ui_runner, std::move(wrapped_callback))));
}

void OWLHistoryService::AddVisitOnDbThread(std::string url,
                                           std::string title,
                                           bool skip_insert,
                                           AddVisitCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  if (!db_) {
    std::move(callback).Run(false);
    return;
  }

  bool ok = false;
  int64_t now_us = TimeToUs(base::Time::Now());

  // Always try UPDATE first (handles both dedupe and revisit cases).
  {
    sql::Statement s(db_->GetCachedStatement(SQL_FROM_HERE,
        "UPDATE visits SET visit_count = visit_count + 1, "
        "last_visit_time = ?, title = ? WHERE url = ?"));
    s.BindInt64(0, now_us);
    s.BindString(1, title);
    s.BindString(2, url);
    ok = s.Run();
  }

  // INSERT only if URL doesn't exist yet and we're not in dedupe window.
  if (!skip_insert && ok && db_->GetLastChangeCount() == 0) {
    sql::Statement s(db_->GetCachedStatement(SQL_FROM_HERE,
        "INSERT INTO visits(url, title, visit_time, last_visit_time, "
        "visit_count) VALUES(?, ?, ?, ?, 1)"));
    s.BindString(0, url);
    s.BindString(1, title);
    s.BindInt64(2, now_us);
    s.BindInt64(3, now_us);
    ok = s.Run();
  }

  if (!ok) {
    GURL parsed_url(url);
    LOG(WARNING) << "[OWL] Failed to add visit for "
                 << parsed_url.scheme() << "://" << parsed_url.host()
                 << " error=" << db_->GetErrorMessage()
                 << " code=" << db_->GetErrorCode();
  }

  std::move(callback).Run(ok);
}

void OWLHistoryService::QueryByTime(const std::string& search_query,
                                    int max_results,
                                    int offset,
                                    QueryCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_ || !db_task_runner_) {
    std::move(callback).Run(std::vector<HistoryEntry>(), 0);
    return;
  }
  max_results = std::max(1, std::min(max_results, 1000));
  offset = std::max(0, offset);

  auto ui_runner = base::SequencedTaskRunner::GetCurrentDefault();
  db_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&OWLHistoryService::QueryByTimeOnDbThread,
                     base::Unretained(this), search_query, max_results, offset,
                     base::BindPostTask(ui_runner, std::move(callback))));
}

void OWLHistoryService::QueryByTimeOnDbThread(std::string query,
                                              int max,
                                              int offset,
                                              QueryCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  std::vector<HistoryEntry> entries;
  int total = 0;

  if (!db_) {
    std::move(callback).Run(std::move(entries), total);
    return;
  }

  if (query.empty()) {
    // Full listing.
    {
      sql::Statement count_s(
          db_->GetUniqueStatement("SELECT COUNT(*) FROM visits"));
      if (count_s.Step()) {
        total = count_s.ColumnInt(0);
      }
    }
    {
      sql::Statement s(db_->GetUniqueStatement(
          "SELECT id, url, title, visit_time, last_visit_time, visit_count "
          "FROM visits ORDER BY last_visit_time DESC LIMIT ? OFFSET ?"));
      s.BindInt(0, max);
      s.BindInt(1, offset);
      while (s.Step()) {
        entries.push_back(RowToEntry(&s));
      }
    }
  } else {
    std::string like_pattern = BuildLikePattern(query);
    if (like_pattern.empty()) {
      std::move(callback).Run(std::move(entries), total);
      return;
    }
    {
      sql::Statement count_s(db_->GetUniqueStatement(
          "SELECT COUNT(*) FROM visits_search "
          "WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'"));
      count_s.BindString(0, like_pattern);
      count_s.BindString(1, like_pattern);
      if (count_s.Step()) {
        total = count_s.ColumnInt(0);
      }
    }
    {
      sql::Statement s(db_->GetUniqueStatement(
          "SELECT v.id, v.url, v.title, v.visit_time, v.last_visit_time, "
          "v.visit_count FROM visits v "
          "JOIN visits_search s ON v.id = s.visit_id "
          "WHERE s.url LIKE ? ESCAPE '\\' OR s.title LIKE ? ESCAPE '\\' "
          "ORDER BY v.last_visit_time DESC LIMIT ? OFFSET ?"));
      s.BindString(0, like_pattern);
      s.BindString(1, like_pattern);
      s.BindInt(2, max);
      s.BindInt(3, offset);
      while (s.Step()) {
        entries.push_back(RowToEntry(&s));
      }
    }
  }

  std::move(callback).Run(std::move(entries), total);
}

void OWLHistoryService::QueryByVisitCount(const std::string& search_query,
                                          int max_results,
                                          QueryEntriesCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_ || !db_task_runner_) {
    std::move(callback).Run(std::vector<HistoryEntry>());
    return;
  }
  max_results = std::max(1, std::min(max_results, 1000));

  auto ui_runner = base::SequencedTaskRunner::GetCurrentDefault();
  db_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&OWLHistoryService::QueryByVisitCountOnDbThread,
                     base::Unretained(this), search_query, max_results,
                     base::BindPostTask(ui_runner, std::move(callback))));
}

void OWLHistoryService::QueryByVisitCountOnDbThread(
    std::string query,
    int max,
    QueryEntriesCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  std::vector<HistoryEntry> entries;

  if (!db_) {
    std::move(callback).Run(std::move(entries));
    return;
  }

  if (query.empty()) {
    sql::Statement s(db_->GetUniqueStatement(
        "SELECT id, url, title, visit_time, last_visit_time, visit_count "
        "FROM visits ORDER BY visit_count DESC LIMIT ?"));
    s.BindInt(0, max);
    while (s.Step()) {
      entries.push_back(RowToEntry(&s));
    }
  } else {
    // URL prefix match (LIKE prefix% uses B-tree index).
    sql::Statement s(db_->GetUniqueStatement(
        "SELECT id, url, title, visit_time, last_visit_time, visit_count "
        "FROM visits WHERE url LIKE ? || '%' "
        "ORDER BY visit_count DESC LIMIT ?"));
    s.BindString(0, query);
    s.BindInt(1, max);
    while (s.Step()) {
      entries.push_back(RowToEntry(&s));
    }
  }

  std::move(callback).Run(std::move(entries));
}

void OWLHistoryService::Delete(const std::string& url,
                               BoolCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_ || !db_task_runner_) {
    std::move(callback).Run(false);
    return;
  }
  std::string normalized = NormalizeUrl(url);
  recent_visits_.erase(normalized);

  auto ui_runner = base::SequencedTaskRunner::GetCurrentDefault();
  db_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&OWLHistoryService::DeleteOnDbThread,
                     base::Unretained(this), normalized,
                     base::BindPostTask(ui_runner, std::move(callback))));
}

void OWLHistoryService::DeleteOnDbThread(std::string url,
                                         BoolCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  bool ok = false;
  if (db_) {
    sql::Statement s(
        db_->GetCachedStatement(SQL_FROM_HERE,
                                "DELETE FROM visits WHERE url = ?"));
    s.BindString(0, url);
    ok = s.Run();
  }

  std::move(callback).Run(ok);
}

void OWLHistoryService::DeleteRange(base::Time start,
                                    base::Time end,
                                    IntCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_ || !db_task_runner_) {
    std::move(callback).Run(0);
    return;
  }
  auto ui_runner = base::SequencedTaskRunner::GetCurrentDefault();
  db_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&OWLHistoryService::DeleteRangeOnDbThread,
                     base::Unretained(this), start, end,
                     base::BindPostTask(ui_runner, std::move(callback))));
}

void OWLHistoryService::DeleteRangeOnDbThread(base::Time start,
                                              base::Time end,
                                              IntCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  int deleted = 0;
  if (db_) {
    sql::Statement s(db_->GetCachedStatement(
        SQL_FROM_HERE,
        "DELETE FROM visits WHERE last_visit_time >= ? AND "
        "last_visit_time < ?"));
    s.BindInt64(0, TimeToUs(start));
    s.BindInt64(1, TimeToUs(end));
    if (s.Run()) {
      deleted = db_->GetLastChangeCount();
    }
  }

  std::move(callback).Run(deleted);
}

void OWLHistoryService::Clear(BoolCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (is_shutdown_ || !db_task_runner_) {
    std::move(callback).Run(false);
    return;
  }
  recent_visits_.clear();

  auto ui_runner = base::SequencedTaskRunner::GetCurrentDefault();
  db_task_runner_->PostTask(
      FROM_HERE, base::BindOnce(&OWLHistoryService::ClearOnDbThread,
                                base::Unretained(this),
                                base::BindPostTask(ui_runner,
                                                   std::move(callback))));
}

void OWLHistoryService::ClearOnDbThread(BoolCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(db_sequence_checker_);
  bool ok = false;
  if (db_) {
    sql::Transaction transaction(db_.get());
    if (transaction.Begin()) {
      ok = db_->Execute("DELETE FROM visits");
      if (ok) {
        ok = transaction.Commit();
      }
    }
  }

  std::move(callback).Run(ok);
}

}  // namespace owl
