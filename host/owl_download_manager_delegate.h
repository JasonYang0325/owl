// Copyright 2026 AntlerAI. All rights reserved.

#ifndef THIRD_PARTY_OWL_HOST_OWL_DOWNLOAD_MANAGER_DELEGATE_H_
#define THIRD_PARTY_OWL_HOST_OWL_DOWNLOAD_MANAGER_DELEGATE_H_

#include <cstdint>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/sequence_checker.h"
#include "base/task/sequenced_task_runner.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/download_manager_delegate.h"
#include "url/gurl.h"

namespace owl {

class OWLDownloadService;

// Implements content::DownloadManagerDelegate and
// content::DownloadManager::Observer. Intercepts download requests and
// determines the target save path (~/Downloads) on a background thread.
// Must be created and used on the UI sequence.
class OWLDownloadManagerDelegate
    : public content::DownloadManagerDelegate,
      public content::DownloadManager::Observer {
 public:
  OWLDownloadManagerDelegate();
  ~OWLDownloadManagerDelegate() override;

  OWLDownloadManagerDelegate(const OWLDownloadManagerDelegate&) = delete;
  OWLDownloadManagerDelegate& operator=(const OWLDownloadManagerDelegate&) =
      delete;

  // Connects to the DownloadManager. Must be called before downloads begin.
  void SetDownloadManager(content::DownloadManager* manager);

  // Sets the OWLDownloadService that receives new-download notifications.
  void SetDownloadService(OWLDownloadService* service);

  // Provides access to the DownloadManager for OWLDownloadService.
  content::DownloadManager* download_manager() const {
    return download_manager_;
  }

  // content::DownloadManagerDelegate:
  void Shutdown() override;
  void GetNextId(content::DownloadIdCallback callback) override;
  bool DetermineDownloadTarget(
      download::DownloadItem* item,
      download::DownloadTargetCallback* callback) override;
  bool ShouldCompleteDownload(
      download::DownloadItem* item,
      base::OnceClosure complete_callback) override;
  void GetSaveDir(content::BrowserContext* context,
                  base::FilePath* website_save_dir,
                  base::FilePath* download_save_dir) override;
  download::QuarantineConnectionCallback GetQuarantineConnectionCallback()
      override;

  // content::DownloadManager::Observer:
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override;
  void ManagerGoingDown(content::DownloadManager* manager) override;

 private:
  // Computes the final save path on a background thread. Uses
  // net::GenerateFileName() for name generation and base::GetUniquePath()
  // for deduplication.
  static base::FilePath ComputeTargetPathOnFileThread(
      const GURL& url,
      const std::string& content_disposition,
      const std::string& suggested_filename,
      const std::string& mime_type,
      const base::FilePath& download_dir);

  uint32_t next_id_ = 1;
  raw_ptr<content::DownloadManager> download_manager_ = nullptr;
  raw_ptr<OWLDownloadService> download_service_ = nullptr;
  scoped_refptr<base::SequencedTaskRunner> file_task_runner_;

  SEQUENCE_CHECKER(ui_sequence_checker_);
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_DOWNLOAD_MANAGER_DELEGATE_H_
