// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_bookmark_service.h"

#include <optional>

#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "third_party/owl/mojom/bookmarks.mojom.h"
#include "url/gurl.h"

namespace owl {

namespace {

constexpr size_t kMaxTitleLength = 1024;
constexpr base::TimeDelta kPersistDebounce = base::Seconds(1);

// Convert a BookmarkItem to base::DictValue for JSON serialization.
base::DictValue BookmarkItemToDict(const owl::mojom::BookmarkItemPtr& item) {
  base::DictValue dict;
  dict.Set("id", item->id);
  dict.Set("title", item->title);
  dict.Set("url", item->url);
  if (item->parent_id.has_value()) {
    dict.Set("parent_id", item->parent_id.value());
  }
  return dict;
}

// Parse a base::DictValue into a BookmarkItem. Returns nullptr on failure.
owl::mojom::BookmarkItemPtr DictToBookmarkItem(const base::DictValue& dict) {
  const std::string* id = dict.FindString("id");
  const std::string* title = dict.FindString("title");
  const std::string* url = dict.FindString("url");
  if (!id || !title || !url) {
    return nullptr;
  }

  // Validate loaded data.
  if (!OWLBookmarkService::IsTitleValid(*title) ||
      !OWLBookmarkService::IsUrlAllowed(*url)) {
    LOG(WARNING) << "[OWL] Skipping invalid bookmark id=" << *id
                 << " title=" << *title;
    return nullptr;
  }

  auto item = owl::mojom::BookmarkItem::New();
  item->id = *id;
  item->title = *title;
  item->url = *url;
  const std::string* parent_id = dict.FindString("parent_id");
  if (parent_id) {
    item->parent_id = *parent_id;
  }
  return item;
}

}  // namespace

OWLBookmarkService::OWLBookmarkService() {
  DETACH_FROM_SEQUENCE(sequence_checker_);
}

OWLBookmarkService::OWLBookmarkService(const base::FilePath& storage_path)
    : storage_path_(storage_path) {
  DETACH_FROM_SEQUENCE(sequence_checker_);
  if (!storage_path_.empty()) {
    file_task_runner_ = base::ThreadPool::CreateSequencedTaskRunner(
        {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  }
}

OWLBookmarkService::~OWLBookmarkService() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  // Synchronous flush on destruction to avoid data loss.
  if (persist_timer_.IsRunning() && !storage_path_.empty()) {
    persist_timer_.Stop();
    PersistNow();
  }
}

void OWLBookmarkService::Bind(
    mojo::PendingReceiver<owl::mojom::BookmarkService> receiver) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  AddReceiver(std::move(receiver));
}

void OWLBookmarkService::AddReceiver(
    mojo::PendingReceiver<owl::mojom::BookmarkService> receiver) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  receivers_.Add(this, std::move(receiver));
  // Load bookmarks on first bind (lazy).
  if (!loaded_) {
    LoadFromFile();
    loaded_ = true;
  }
}

// static
bool OWLBookmarkService::IsUrlAllowed(const std::string& url) {
  GURL gurl(url);
  return gurl.is_valid() && (gurl.SchemeIs("http") || gurl.SchemeIs("https"));
}

// static
bool OWLBookmarkService::IsTitleValid(const std::string& title) {
  return !title.empty() && title.size() <= kMaxTitleLength;
}

std::string OWLBookmarkService::GenerateId() {
  return base::NumberToString(next_id_++);
}

void OWLBookmarkService::GetAll(GetAllCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<owl::mojom::BookmarkItemPtr> result;
  for (const auto& item : bookmarks_) {
    result.push_back(item->Clone());
  }
  std::move(callback).Run(std::move(result));
}

void OWLBookmarkService::Add(const std::string& title,
                              const std::string& url,
                              const std::optional<std::string>& parent_id,
                              AddCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  if (!IsTitleValid(title) || !IsUrlAllowed(url)) {
    std::move(callback).Run(nullptr);
    return;
  }

  auto item = owl::mojom::BookmarkItem::New();
  item->id = GenerateId();
  item->title = title;
  item->url = url;
  if (parent_id.has_value()) {
    item->parent_id = parent_id.value();
  }

  auto result = item->Clone();
  bookmarks_.push_back(std::move(item));
  SchedulePersist();
  std::move(callback).Run(std::move(result));
}

void OWLBookmarkService::Remove(const std::string& id,
                                 RemoveCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = std::find_if(bookmarks_.begin(), bookmarks_.end(),
                         [&id](const auto& item) { return item->id == id; });
  if (it != bookmarks_.end()) {
    bookmarks_.erase(it);
    SchedulePersist();
    std::move(callback).Run(true);
  } else {
    std::move(callback).Run(false);
  }
}

void OWLBookmarkService::Update(const std::string& id,
                                 const std::optional<std::string>& title,
                                 const std::optional<std::string>& url,
                                 UpdateCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  // Validate inputs if provided.
  if (title.has_value() && !IsTitleValid(title.value())) {
    std::move(callback).Run(false);
    return;
  }
  if (url.has_value() && !IsUrlAllowed(url.value())) {
    std::move(callback).Run(false);
    return;
  }

  for (auto& item : bookmarks_) {
    if (item->id == id) {
      if (title.has_value()) {
        item->title = title.value();
      }
      if (url.has_value()) {
        item->url = url.value();
      }
      SchedulePersist();
      std::move(callback).Run(true);
      return;
    }
  }
  std::move(callback).Run(false);
}

void OWLBookmarkService::LoadFromFile() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (storage_path_.empty()) {
    return;  // Memory-only mode.
  }

  std::string contents;
  if (!base::ReadFileToString(storage_path_, &contents)) {
    // File doesn't exist yet — that's fine.
    return;
  }

  auto parsed = base::JSONReader::Read(contents, base::JSON_PARSE_RFC);
  if (!parsed) {
    LOG(ERROR) << "[OWL] Failed to parse bookmarks.json";
    return;
  }

  // Expected format: {"version":1, "bookmarks":[...], "next_id":N}
  if (!parsed->is_dict()) {
    LOG(ERROR) << "[OWL] bookmarks.json is not a dict";
    return;
  }

  const auto& root = parsed->GetDict();
  const base::ListValue* bookmarks_list = root.FindList("bookmarks");
  if (!bookmarks_list) {
    return;  // No bookmarks array — treat as empty.
  }

  int max_id = 0;
  for (const auto& entry : *bookmarks_list) {
    if (!entry.is_dict()) {
      continue;
    }
    auto item = DictToBookmarkItem(entry.GetDict());
    if (item) {
      int id_num = 0;
      if (base::StringToInt(item->id, &id_num) && id_num > max_id) {
        max_id = id_num;
      }
      bookmarks_.push_back(std::move(item));
    }
  }

  // Restore next_id from file (if present), otherwise use max_id + 1.
  auto saved_next_id = root.FindInt("next_id");
  if (saved_next_id.has_value() && saved_next_id.value() > max_id) {
    next_id_ = saved_next_id.value();
  } else {
    next_id_ = max_id + 1;
  }
  LOG(INFO) << "[OWL] Loaded " << bookmarks_.size() << " bookmarks from "
            << storage_path_.value();
}

void OWLBookmarkService::SchedulePersist() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (storage_path_.empty()) {
    return;  // Memory-only mode.
  }

  // Debounce: restart timer on each mutation.
  persist_timer_.Start(FROM_HERE, kPersistDebounce,
                       base::BindOnce(&OWLBookmarkService::PersistNow,
                                      base::Unretained(this)));
}

void OWLBookmarkService::PersistNow() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (storage_path_.empty()) {
    return;
  }

  std::string json = SerializeToJson();

  if (!file_task_runner_) {
    // Fallback: synchronous write (e.g., during destruction after
    // thread pool shutdown).
    base::FilePath dir = storage_path_.DirName();
    base::CreateDirectory(dir);
    base::FilePath temp_path = storage_path_.AddExtension(FILE_PATH_LITERAL("tmp"));
    if (base::WriteFile(temp_path, json)) {
      base::Move(temp_path, storage_path_);
    }
    return;
  }

  file_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::FilePath path, std::string data) {
            base::FilePath dir = path.DirName();
            base::CreateDirectory(dir);
            // Atomic write: write to temp file + rename.
            base::FilePath temp_path =
                path.AddExtension(FILE_PATH_LITERAL("tmp"));
            if (base::WriteFile(temp_path, data)) {
              base::Move(temp_path, path);
            } else {
              LOG(ERROR) << "[OWL] Failed to write bookmarks to "
                         << temp_path.value();
            }
          },
          storage_path_, std::move(json)));
}

std::string OWLBookmarkService::SerializeToJson() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  base::ListValue list;
  for (const auto& item : bookmarks_) {
    list.Append(BookmarkItemToDict(item));
  }
  base::DictValue root;
  root.Set("version", 1);
  root.Set("bookmarks", std::move(list));
  root.Set("next_id", next_id_);
  std::string json;
  base::JSONWriter::WriteWithOptions(
      root, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json);
  return json;
}

}  // namespace owl
