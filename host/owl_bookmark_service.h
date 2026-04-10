// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_HOST_OWL_BOOKMARK_SERVICE_H_
#define THIRD_PARTY_OWL_HOST_OWL_BOOKMARK_SERVICE_H_

#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/sequence_checker.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "third_party/owl/mojom/bookmarks.mojom.h"

namespace owl {

// Implements owl.mojom.BookmarkService with file-based persistence.
// All methods run on the UI thread. File I/O is posted to a dedicated
// SequencedTaskRunner, except ~OWLBookmarkService which flushes
// synchronously to avoid data loss.
//
// If |storage_path| is empty (off-the-record), operates in memory-only mode.
class OWLBookmarkService : public owl::mojom::BookmarkService {
 public:
  // Memory-only mode (no persistence). Used by tests and off-the-record.
  OWLBookmarkService();
  // |storage_path|: path to bookmarks.json. Empty = memory-only mode.
  explicit OWLBookmarkService(const base::FilePath& storage_path);
  ~OWLBookmarkService() override;

  OWLBookmarkService(const OWLBookmarkService&) = delete;
  OWLBookmarkService& operator=(const OWLBookmarkService&) = delete;

  // Bind a single receiver (convenience, delegates to AddReceiver).
  void Bind(mojo::PendingReceiver<owl::mojom::BookmarkService> receiver);

  // Add a new pipe endpoint (multiple clients supported via ReceiverSet).
  void AddReceiver(mojo::PendingReceiver<owl::mojom::BookmarkService> receiver);

  // owl::mojom::BookmarkService:
  void GetAll(GetAllCallback callback) override;
  void Add(const std::string& title, const std::string& url,
           const std::optional<std::string>& parent_id,
           AddCallback callback) override;
  void Remove(const std::string& id, RemoveCallback callback) override;
  void Update(const std::string& id,
              const std::optional<std::string>& title,
              const std::optional<std::string>& url,
              UpdateCallback callback) override;

  // For testing.
  size_t count() const { return bookmarks_.size(); }

  // Input validation (public for testing).
  static bool IsUrlAllowed(const std::string& url);
  static bool IsTitleValid(const std::string& title);

  // Persistence (public for testing).
  void LoadFromFile();
  void PersistNow();

 private:
  std::string GenerateId();
  void SchedulePersist();
  std::string SerializeToJson() const;

  const base::FilePath storage_path_;
  mojo::ReceiverSet<owl::mojom::BookmarkService> receivers_;
  std::vector<owl::mojom::BookmarkItemPtr> bookmarks_;
  int next_id_ = 1;

  // Debounce timer for persistence (1 second).
  base::OneShotTimer persist_timer_;

  // File I/O task runner.
  scoped_refptr<base::SequencedTaskRunner> file_task_runner_;

  // Whether bookmarks have been loaded from file (prevents duplicate loads).
  bool loaded_ = false;

  SEQUENCE_CHECKER(sequence_checker_);
};

}  // namespace owl
#endif  // THIRD_PARTY_OWL_HOST_OWL_BOOKMARK_SERVICE_H_
