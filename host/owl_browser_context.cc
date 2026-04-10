// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_browser_context.h"

#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "components/download/public/common/download_item.h"
#include "third_party/owl/host/owl_bookmark_service.h"
#include "third_party/owl/host/owl_download_service.h"
#include "third_party/owl/host/owl_history_service.h"
#include "third_party/owl/host/owl_permission_manager.h"
#include "third_party/owl/host/owl_permission_service_impl.h"
#include "third_party/owl/host/owl_storage_service.h"
#include "third_party/owl/host/owl_web_contents.h"
#include "third_party/owl/mojom/downloads.mojom.h"
#include "third_party/owl/mojom/history.mojom.h"
#include "url/origin.h"

namespace owl {

// Mojo adapter: bridges owl::mojom::HistoryService to OWLHistoryService.
// Converts Mojo types (owl::mojom::HistoryEntry) <-> C++ types (owl::HistoryEntry).
class HistoryServiceMojoAdapter : public owl::mojom::HistoryService {
 public:
  HistoryServiceMojoAdapter(OWLHistoryService* service,
                            OWLBrowserContext* context)
      : service_(service), context_(context) {}

  void AddReceiver(
      mojo::PendingReceiver<owl::mojom::HistoryService> receiver) {
    receivers_.Add(this, std::move(receiver));
  }

  // owl::mojom::HistoryService:
  void AddVisit(const std::string& url,
                const std::string& title,
                AddVisitCallback callback) override {
    service_->AddVisit(url, title, std::move(callback));
  }

  void QueryByTime(const std::string& search_query,
                   int32_t max_results,
                   int32_t offset,
                   QueryByTimeCallback callback) override {
    service_->QueryByTime(
        search_query, max_results, offset,
        base::BindOnce(
            [](QueryByTimeCallback cb,
               std::vector<HistoryEntry> entries, int total) {
              std::vector<owl::mojom::HistoryEntryPtr> mojom_entries;
              mojom_entries.reserve(entries.size());
              for (const auto& e : entries) {
                auto me = owl::mojom::HistoryEntry::New();
                me->id = e.id;
                me->url = e.url;
                me->title = e.title;
                me->visit_time = e.visit_time;
                me->last_visit_time = e.last_visit_time;
                me->visit_count = e.visit_count;
                mojom_entries.push_back(std::move(me));
              }
              std::move(cb).Run(std::move(mojom_entries), total);
            },
            std::move(callback)));
  }

  void QueryByVisitCount(const std::string& search_query,
                         int32_t max_results,
                         QueryByVisitCountCallback callback) override {
    service_->QueryByVisitCount(
        search_query, max_results,
        base::BindOnce(
            [](QueryByVisitCountCallback cb,
               std::vector<HistoryEntry> entries) {
              std::vector<owl::mojom::HistoryEntryPtr> mojom_entries;
              mojom_entries.reserve(entries.size());
              for (const auto& e : entries) {
                auto me = owl::mojom::HistoryEntry::New();
                me->id = e.id;
                me->url = e.url;
                me->title = e.title;
                me->visit_time = e.visit_time;
                me->last_visit_time = e.last_visit_time;
                me->visit_count = e.visit_count;
                mojom_entries.push_back(std::move(me));
              }
              std::move(cb).Run(std::move(mojom_entries));
            },
            std::move(callback)));
  }

  void Delete(const std::string& url, DeleteCallback callback) override {
    service_->Delete(url, std::move(callback));
  }

  void DeleteRange(base::Time start,
                   base::Time end,
                   DeleteRangeCallback callback) override {
    service_->DeleteRange(start, end, std::move(callback));
  }

  void Clear(ClearCallback callback) override {
    service_->Clear(std::move(callback));
  }

  void SetObserver(
      mojo::PendingRemote<owl::mojom::HistoryObserver> observer) override {
    if (context_) {
      context_->SetHistoryObserver(std::move(observer));
    }
  }

 private:
  raw_ptr<OWLHistoryService> service_;
  raw_ptr<OWLBrowserContext> context_;
  mojo::ReceiverSet<owl::mojom::HistoryService> receivers_;
};

// Mojo adapter: bridges owl::mojom::DownloadService to OWLDownloadService.
// Converts download::DownloadItem* <-> owl::mojom::DownloadItem.
class DownloadServiceMojoAdapter : public owl::mojom::DownloadService {
 public:
  DownloadServiceMojoAdapter(OWLDownloadService* service,
                              OWLBrowserContext* context)
      : service_(service), context_(context) {}

  void AddReceiver(
      mojo::PendingReceiver<owl::mojom::DownloadService> receiver) {
    receivers_.Add(this, std::move(receiver));
  }

  // owl::mojom::DownloadService:
  void GetAll(GetAllCallback callback) override {
    auto items = service_->GetAllDownloads();
    std::vector<owl::mojom::DownloadItemPtr> mojom_items;
    mojom_items.reserve(items.size());
    for (auto* item : items) {
      mojom_items.push_back(ToMojom(item));
    }
    std::move(callback).Run(std::move(mojom_items));
  }

  void Pause(uint32_t download_id) override {
    service_->PauseDownload(download_id);
  }

  void Resume(uint32_t download_id) override {
    service_->ResumeDownload(download_id);
  }

  void Cancel(uint32_t download_id) override {
    service_->CancelDownload(download_id);
  }

  void RemoveEntry(uint32_t download_id) override {
    service_->RemoveEntry(download_id);
  }

  void OpenFile(uint32_t download_id) override {
    service_->OpenFile(download_id);
  }

  void ShowInFolder(uint32_t download_id) override {
    service_->ShowInFolder(download_id);
  }

  // Public so OWLBrowserContext can call it for observer push.
  static owl::mojom::DownloadItemPtr ToMojom(download::DownloadItem* item) {
    auto result = owl::mojom::DownloadItem::New();
    result->id = item->GetId();
    result->url = item->GetURL().spec();
    result->filename = item->GetTargetFilePath().BaseName().AsUTF8Unsafe();
    result->mime_type = item->GetMimeType();
    result->total_bytes = item->GetTotalBytes();
    result->received_bytes = item->GetReceivedBytes();
    result->speed_bytes_per_sec = item->CurrentSpeed();
    result->state = MapState(item);
    result->can_resume = item->CanResume();
    result->target_path = item->GetTargetFilePath().AsUTF8Unsafe();
    if (item->GetState() == download::DownloadItem::INTERRUPTED) {
      result->error_description = MapErrorDescription(item->GetLastReason());
    }
    return result;
  }

 private:
  static owl::mojom::DownloadState MapState(download::DownloadItem* item) {
    switch (item->GetState()) {
      case download::DownloadItem::IN_PROGRESS:
        return item->IsPaused() ? owl::mojom::DownloadState::kPaused
                                : owl::mojom::DownloadState::kInProgress;
      case download::DownloadItem::COMPLETE:
        return owl::mojom::DownloadState::kComplete;
      case download::DownloadItem::CANCELLED:
        return owl::mojom::DownloadState::kCancelled;
      case download::DownloadItem::INTERRUPTED:
        return owl::mojom::DownloadState::kInterrupted;
      default:
        return owl::mojom::DownloadState::kInProgress;
    }
  }

  static std::string MapErrorDescription(
      download::DownloadInterruptReason reason) {
    switch (reason) {
      case download::DOWNLOAD_INTERRUPT_REASON_FILE_NO_SPACE:
        return "Insufficient disk space";
      case download::DOWNLOAD_INTERRUPT_REASON_FILE_NAME_TOO_LONG:
        return "File name too long";
      case download::DOWNLOAD_INTERRUPT_REASON_FILE_ACCESS_DENIED:
        return "Access denied";
      case download::DOWNLOAD_INTERRUPT_REASON_NETWORK_FAILED:
        return "Network error";
      case download::DOWNLOAD_INTERRUPT_REASON_NETWORK_TIMEOUT:
        return "Network timeout";
      case download::DOWNLOAD_INTERRUPT_REASON_NETWORK_DISCONNECTED:
        return "Network disconnected";
      case download::DOWNLOAD_INTERRUPT_REASON_SERVER_FAILED:
        return "Server error";
      case download::DOWNLOAD_INTERRUPT_REASON_USER_CANCELED:
        return "Cancelled by user";
      default:
        return "Download interrupted";
    }
  }

  raw_ptr<OWLDownloadService> service_;
  raw_ptr<OWLBrowserContext> context_;
  mojo::ReceiverSet<owl::mojom::DownloadService> receivers_;
};


OWLBrowserContext::OWLBrowserContext(const std::string& partition_name,
                                     bool off_the_record,
                                     const base::FilePath& user_data_dir,
                                     OWLPermissionManager* permission_manager,
                                     OWLDownloadService* download_service,
                                     DestroyedCallback destroyed_callback)
    : partition_name_(partition_name),
      off_the_record_(off_the_record),
      user_data_dir_(user_data_dir),
      destroyed_callback_(std::move(destroyed_callback)),
      permission_manager_(permission_manager) {
  SetDownloadService(download_service);
}

OWLBrowserContext::OWLBrowserContext(const std::string& partition_name,
                                     bool off_the_record,
                                     const base::FilePath& user_data_dir,
                                     DestroyedCallback destroyed_callback)
    : OWLBrowserContext(partition_name,
                        off_the_record,
                        user_data_dir,
                        /*permission_manager=*/nullptr,
                        /*download_service=*/nullptr,
                        std::move(destroyed_callback)) {}

void OWLBrowserContext::SetDownloadService(OWLDownloadService* service) {
  if (download_service_ == service) {
    return;
  }

  // Unregister from previous service first.
  if (download_service_) {
    download_service_->SetChangedCallback({});
    download_service_->SetRemovedCallback({});
  }

  // Adapter is tied to a specific service pointer.
  download_mojo_adapter_.reset();
  download_service_ = service;

  if (download_service_) {
    download_service_->SetChangedCallback(
        base::BindRepeating(&OWLBrowserContext::OnDownloadChanged,
                            weak_factory_.GetWeakPtr()));
    download_service_->SetRemovedCallback(
        base::BindRepeating(&OWLBrowserContext::OnDownloadRemoved,
                            weak_factory_.GetWeakPtr()));
  }
}

OWLBrowserContext::~OWLBrowserContext() {
  DestroyInternal();
}

void OWLBrowserContext::Bind(
    mojo::PendingReceiver<owl::mojom::BrowserContextHost> receiver) {
  receiver_.Bind(std::move(receiver));
  receiver_.set_disconnect_handler(base::BindOnce(
      &OWLBrowserContext::OnDisconnect, base::Unretained(this)));
}

void OWLBrowserContext::OnDisconnect() {
  DestroyInternal();
}

void OWLBrowserContext::CreateWebView(
    mojo::PendingRemote<owl::mojom::WebViewObserver> observer,
    CreateWebViewCallback callback) {
  uint64_t webview_id = next_webview_id_++;

  auto web_contents = std::make_unique<OWLWebContents>(
      webview_id, this,
      base::BindOnce(&OWLBrowserContext::OnWebViewClosed,
                     weak_factory_.GetWeakPtr()));

  mojo::PendingRemote<owl::mojom::WebViewHost> web_view_remote;
  web_contents->Bind(web_view_remote.InitWithNewPipeAndPassReceiver());
  web_contents->SetInitialObserver(std::move(observer));

  web_view_map_.emplace(webview_id, std::move(web_contents));
  std::move(callback).Run(webview_id, std::move(web_view_remote));
}

void OWLBrowserContext::GetBookmarkService(
    GetBookmarkServiceCallback callback) {
  // Lazy create the bookmark service on first request.
  if (!bookmark_service_) {
    base::FilePath storage_path;
    if (!off_the_record_ && !user_data_dir_.empty()) {
      storage_path = user_data_dir_.Append(FILE_PATH_LITERAL("bookmarks.json"));
    }
    // off_the_record or empty user_data_dir → empty path → memory-only mode.
    bookmark_service_ = std::make_unique<OWLBookmarkService>(storage_path);
  }

  mojo::PendingRemote<owl::mojom::BookmarkService> remote;
  bookmark_service_->AddReceiver(remote.InitWithNewPipeAndPassReceiver());
  std::move(callback).Run(std::move(remote));
}

void OWLBrowserContext::GetHistoryService(
    GetHistoryServiceCallback callback) {
  // Ensure the underlying history service exists.
  GetHistoryServiceRaw();

  // Lazy-create the adapter (cached — one adapter, multiple pipe endpoints).
  if (!history_mojo_adapter_) {
    history_mojo_adapter_ = std::make_unique<HistoryServiceMojoAdapter>(
        history_service_.get(), this);
  }

  // Each call gets a new pipe endpoint added to the ReceiverSet.
  mojo::PendingRemote<owl::mojom::HistoryService> remote;
  history_mojo_adapter_->AddReceiver(remote.InitWithNewPipeAndPassReceiver());

  std::move(callback).Run(std::move(remote));
}

void OWLBrowserContext::GetPermissionService(
    GetPermissionServiceCallback callback) {
  // PermissionService is non-nullable in Mojom — returning NullRemote() would
  // fail Mojo validation and tear down the entire BrowserContext pipe.
  // When no external PermissionManager was injected, lazily create a
  // memory-only fallback so the pipe stays alive.
  if (!permission_manager_) {
    fallback_permission_manager_ =
        std::make_unique<OWLPermissionManager>(base::FilePath());
    permission_manager_ = fallback_permission_manager_.get();
  }

  // Lazy-create the adapter (cached — one adapter, multiple pipe endpoints).
  if (!permission_mojo_adapter_) {
    permission_mojo_adapter_ = std::make_unique<OWLPermissionServiceImpl>(
        permission_manager_);
  }

  // Each call gets a new pipe endpoint added to the ReceiverSet.
  mojo::PendingRemote<owl::mojom::PermissionService> remote;
  permission_mojo_adapter_->AddReceiver(
      remote.InitWithNewPipeAndPassReceiver());

  std::move(callback).Run(std::move(remote));
}

OWLHistoryService* OWLBrowserContext::GetHistoryServiceRaw() {
  if (destroyed_) {
    return nullptr;
  }
  if (!history_service_) {
    base::FilePath db_path;
    if (!off_the_record_ && !user_data_dir_.empty()) {
      db_path = user_data_dir_.Append(FILE_PATH_LITERAL("history.db"));
    }
    // off_the_record or empty user_data_dir → empty path → memory-only mode.
    if (db_path.empty()) {
      history_service_ = std::make_unique<OWLHistoryService>();
    } else {
      history_service_ = std::make_unique<OWLHistoryService>(db_path);
    }
    // Register change callback so history_observer_ gets notified.
    history_service_->SetChangeCallback(base::BindRepeating(
        &OWLBrowserContext::OnHistoryChanged, weak_factory_.GetWeakPtr()));
  }
  // Set global pointer for RealWebContents to use in DidFinishNavigation.
  g_owl_history_service = history_service_.get();
  return history_service_.get();
}

void OWLBrowserContext::SetHistoryObserver(
    mojo::PendingRemote<owl::mojom::HistoryObserver> observer) {
  history_observer_.Bind(std::move(observer));
}

void OWLBrowserContext::OnHistoryChanged(const std::string& url) {
  if (history_observer_.is_bound() && history_observer_.is_connected()) {
    history_observer_->OnHistoryChanged(url);
  }
}

void OWLBrowserContext::GetDownloadService(
    GetDownloadServiceCallback callback) {
  if (!download_service_) {
    std::move(callback).Run(mojo::NullRemote());
    return;
  }

  // Lazy-create the adapter (cached — one adapter, multiple pipe endpoints).
  if (!download_mojo_adapter_) {
    download_mojo_adapter_ = std::make_unique<DownloadServiceMojoAdapter>(
        download_service_, this);
  }

  // Each call gets a new pipe endpoint added to the ReceiverSet.
  mojo::PendingRemote<owl::mojom::DownloadService> remote;
  download_mojo_adapter_->AddReceiver(remote.InitWithNewPipeAndPassReceiver());

  std::move(callback).Run(std::move(remote));
}

void OWLBrowserContext::GetStorageService(
    GetStorageServiceCallback callback) {
  // Lazy create the storage service on first request.
  if (!storage_service_) {
    storage_service_ = std::make_unique<OWLStorageService>();
  }

  mojo::PendingRemote<owl::mojom::StorageService> remote;
  storage_service_->AddReceiver(remote.InitWithNewPipeAndPassReceiver());
  std::move(callback).Run(std::move(remote));
}

void OWLBrowserContext::SetDownloadObserver(
    mojo::PendingRemote<owl::mojom::DownloadObserver> observer) {
  download_observer_.Bind(std::move(observer));
}

void OWLBrowserContext::OnDownloadChanged(download::DownloadItem* item,
                                           bool created) {
  if (!download_observer_.is_bound() || !download_observer_.is_connected())
    return;
  auto mojom_item = DownloadServiceMojoAdapter::ToMojom(item);
  if (created) {
    download_observer_->OnDownloadCreated(std::move(mojom_item));
  } else {
    download_observer_->OnDownloadUpdated(std::move(mojom_item));
  }
}

void OWLBrowserContext::OnDownloadRemoved(uint32_t id) {
  if (!download_observer_.is_bound() || !download_observer_.is_connected())
    return;
  download_observer_->OnDownloadRemoved(id);
}

void OWLBrowserContext::DestroyInternal() {
  if (destroyed_) {
    return;  // Idempotent guard.
  }
  destroyed_ = true;

  // First clear WebViews — ~OWLWebContents will detach RealWebContents.
  // Move to local variable to prevent reentrant modification via
  // closed_callback_ during ~OWLWebContents.
  auto local_map = std::move(web_view_map_);
  local_map.clear();

  // Shutdown history service (WAL checkpoint + wait for pending ops).
  if (history_service_) {
    history_observer_.reset();
    history_mojo_adapter_.reset();
    history_service_->Shutdown();
    history_service_.reset();
    // Clear global pointer (RealWebContents may still reference it).
    g_owl_history_service = nullptr;
  }
  // Destroy bookmark service (triggers synchronous flush if dirty).
  bookmark_service_.reset();
  // Destroy storage service.
  storage_service_.reset();
  // Destroy permission adapter, then the fallback manager (if any).
  permission_mojo_adapter_.reset();
  permission_manager_ = nullptr;
  fallback_permission_manager_.reset();
  // Download cleanup (not owned, just clear references).
  download_observer_.reset();
  download_mojo_adapter_.reset();
  // Do not call into download_service_ here: it may have already been
  // destroyed by external owner.
  download_service_ = nullptr;

  // Notify parent (OWLBrowserImpl) that we're destroyed.
  // OnceClosure ensures this fires at most once; called synchronously so
  // the Shutdown() path (which clears the context map) gets notified.
  if (destroyed_callback_) {
    std::move(destroyed_callback_).Run(this);
  }
}

void OWLBrowserContext::Destroy(DestroyCallback callback) {
  // Send callback before DestroyInternal, which may notify parent and trigger
  // deletion — the Mojo pipe must still be connected for the response.
  std::move(callback).Run();

  // Clear disconnect handler before reset to avoid double-triggering.
  receiver_.set_disconnect_handler(base::OnceClosure());
  receiver_.reset();

  DestroyInternal();
}

void OWLBrowserContext::OnWebViewClosed(OWLWebContents* web_contents) {
  std::erase_if(web_view_map_, [web_contents](const auto& pair) {
    return pair.second.get() == web_contents;
  });
}

}  // namespace owl
