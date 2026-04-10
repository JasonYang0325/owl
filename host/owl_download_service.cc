// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_download_service.h"

#include "base/logging.h"
#include "base/notimplemented.h"
#include "base/notreached.h"
#include "third_party/owl/host/owl_download_manager_delegate.h"

namespace owl {

OWLDownloadService::OWLDownloadService(OWLDownloadManagerDelegate* delegate)
    : delegate_(delegate) {
  DETACH_FROM_SEQUENCE(ui_sequence_checker_);
}

OWLDownloadService::~OWLDownloadService() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  DCHECK(observed_items_.empty())
      << "Shutdown() must be called before destruction";
}

void OWLDownloadService::Shutdown() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  for (const auto& item : observed_items_) {
    item->RemoveObserver(this);
  }
  observed_items_.clear();
  delegate_ = nullptr;
}

std::vector<download::DownloadItem*> OWLDownloadService::GetAllDownloads() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  std::vector<download::DownloadItem*> result;
  result.reserve(observed_items_.size());
  for (const auto& item : observed_items_) {
    result.push_back(item);
  }
  return result;
}

download::DownloadItem* OWLDownloadService::FindById(uint32_t id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  for (const auto& item : observed_items_) {
    if (item->GetId() == id) {
      return item;
    }
  }
  return nullptr;
}

void OWLDownloadService::PauseDownload(uint32_t id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  auto* item = FindById(id);
  if (item) {
    item->Pause();
  }
}

void OWLDownloadService::ResumeDownload(uint32_t id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  auto* item = FindById(id);
  if (item) {
    item->Resume(/*user_resume=*/true);
  }
}

void OWLDownloadService::CancelDownload(uint32_t id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  auto* item = FindById(id);
  if (item) {
    item->Cancel(/*user_cancel=*/true);
  }
}

void OWLDownloadService::RemoveEntry(uint32_t id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  auto* item = FindById(id);
  if (item) {
    item->Remove();
  }
}

void OWLDownloadService::OpenFile(uint32_t id) {
  NOTIMPLEMENTED() << "OpenFile will be implemented in Phase 2";
}

void OWLDownloadService::ShowInFolder(uint32_t id) {
  NOTIMPLEMENTED() << "ShowInFolder will be implemented in Phase 2";
}

void OWLDownloadService::OnNewDownload(download::DownloadItem* item) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  auto [it, inserted] = observed_items_.insert(item);
  if (!inserted) {
    // Duplicate registration can happen in tests and edge races.
    // Keep behavior idempotent instead of re-adding observer (which DCHECKs).
    return;
  }
  item->AddObserver(this);
  if (changed_callback_) {
    changed_callback_.Run(item, /*created=*/true);
  }
}

void OWLDownloadService::SetChangedCallback(
    DownloadChangedCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  changed_callback_ = std::move(callback);
}

void OWLDownloadService::SetRemovedCallback(
    DownloadRemovedCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  removed_callback_ = std::move(callback);
}

void OWLDownloadService::OnDownloadUpdated(download::DownloadItem* item) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (changed_callback_) {
    changed_callback_.Run(item, /*created=*/false);
  }
}

void OWLDownloadService::OnDownloadDestroyed(download::DownloadItem* item) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  uint32_t id = item->GetId();
  item->RemoveObserver(this);
  observed_items_.erase(item);
  if (removed_callback_) {
    removed_callback_.Run(id);
  }
}

}  // namespace owl
