// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_download_manager_delegate.h"

#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/task/thread_pool.h"
#include "components/download/public/common/download_danger_type.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_target_info.h"
#include "net/base/filename_util.h"
#include "third_party/owl/host/owl_download_service.h"

#include "base/apple/foundation_util.h"

namespace owl {

OWLDownloadManagerDelegate::OWLDownloadManagerDelegate()
    : file_task_runner_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE})) {
  DETACH_FROM_SEQUENCE(ui_sequence_checker_);
}

OWLDownloadManagerDelegate::~OWLDownloadManagerDelegate() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
}

void OWLDownloadManagerDelegate::SetDownloadManager(
    content::DownloadManager* manager) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (download_manager_) {
    download_manager_->RemoveObserver(this);
  }
  download_manager_ = manager;
  if (download_manager_) {
    download_manager_->AddObserver(this);
  }
}

void OWLDownloadManagerDelegate::SetDownloadService(
    OWLDownloadService* service) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  download_service_ = service;
}

void OWLDownloadManagerDelegate::Shutdown() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (download_manager_) {
    download_manager_->RemoveObserver(this);
    download_manager_ = nullptr;
  }
  download_service_ = nullptr;
}

void OWLDownloadManagerDelegate::GetNextId(
    content::DownloadIdCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  std::move(callback).Run(next_id_++);
}

bool OWLDownloadManagerDelegate::DetermineDownloadTarget(
    download::DownloadItem* item,
    download::DownloadTargetCallback* callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);

  base::FilePath download_dir;
  GetSaveDir(/*context=*/nullptr, /*website_save_dir=*/nullptr, &download_dir);

  if (download_dir.empty()) {
    LOG(ERROR) << "[OWL] Failed to determine download directory";
    return false;
  }

  auto cb = std::move(*callback);
  file_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ComputeTargetPathOnFileThread, item->GetURL(),
                      item->GetContentDisposition(),
                      item->GetSuggestedFilename(), item->GetMimeType(),
                      download_dir),
      base::BindOnce(
          [](download::DownloadTargetCallback callback,
             base::FilePath target_path) {
            download::DownloadTargetInfo info;
            info.target_path = target_path;
            info.intermediate_path =
                target_path.AddExtensionASCII("crdownload");
            info.danger_type =
                download::DOWNLOAD_DANGER_TYPE_NOT_DANGEROUS;
            info.target_disposition =
                download::DownloadItem::TARGET_DISPOSITION_OVERWRITE;
            info.interrupt_reason =
                download::DOWNLOAD_INTERRUPT_REASON_NONE;
            info.insecure_download_status =
                download::DownloadItem::InsecureDownloadStatus::SAFE;
            std::move(callback).Run(std::move(info));
          },
          std::move(cb)));
  return true;
}

bool OWLDownloadManagerDelegate::ShouldCompleteDownload(
    download::DownloadItem* item,
    base::OnceClosure complete_callback) {
  // Allow all downloads to complete immediately.
  return true;
}

void OWLDownloadManagerDelegate::GetSaveDir(
    content::BrowserContext* context,
    base::FilePath* website_save_dir,
    base::FilePath* download_save_dir) {
  if (download_save_dir) {
    base::apple::GetUserDirectory(NSDownloadsDirectory, download_save_dir);
  }
}

download::QuarantineConnectionCallback
OWLDownloadManagerDelegate::GetQuarantineConnectionCallback() {
  // Phase 1: return empty callback. Chromium may handle quarantine
  // automatically on macOS. If integration testing reveals missing xattr,
  // this will be addressed before Phase 2.
  return {};
}

void OWLDownloadManagerDelegate::OnDownloadCreated(
    content::DownloadManager* manager,
    download::DownloadItem* item) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (download_service_) {
    download_service_->OnNewDownload(item);
  }
}

void OWLDownloadManagerDelegate::ManagerGoingDown(
    content::DownloadManager* manager) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  if (download_manager_ == manager) {
    download_manager_->RemoveObserver(this);
    download_manager_ = nullptr;
  }
}

// static
base::FilePath OWLDownloadManagerDelegate::ComputeTargetPathOnFileThread(
    const GURL& url,
    const std::string& content_disposition,
    const std::string& suggested_filename,
    const std::string& mime_type,
    const base::FilePath& download_dir) {
  // Use Chromium's net::GenerateFileName() to determine the filename from
  // Content-Disposition, URL, MIME type, etc.
  base::FilePath generated = net::GenerateFileName(
      url, content_disposition, /*referrer_charset=*/std::string(),
      suggested_filename, mime_type, /*default_name=*/"download");

  base::FilePath target_path = download_dir.Append(generated.BaseName());

  // Use base::GetUniquePath() for atomic deduplication (avoids TOCTOU).
  return base::GetUniquePath(target_path);
}

}  // namespace owl
