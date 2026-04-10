// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_content_browser_context.h"

#include <sys/stat.h>

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "third_party/owl/host/owl_download_service.h"

namespace owl {

OWLContentBrowserContext::OWLContentBrowserContext(bool off_the_record)
    : off_the_record_(off_the_record) {
  // BH-007: Read --user-data-dir from command line, fallback to
  // ~/Library/Application Support/OWLBrowser/.
  const auto* cmd = base::CommandLine::ForCurrentProcess();
  std::string user_data_dir = cmd->GetSwitchValueASCII("user-data-dir");
  if (!user_data_dir.empty()) {
    path_ = base::FilePath(user_data_dir);
  } else {
    base::FilePath home_dir;
    base::PathService::Get(base::DIR_HOME, &home_dir);
    path_ = home_dir.Append(FILE_PATH_LITERAL("Library"))
                .Append(FILE_PATH_LITERAL("Application Support"))
                .Append(FILE_PATH_LITERAL("OWLBrowser"));
  }

  // Create the directory with mode 0700 (owner-only access).
  base::File::Error error;
  if (!base::CreateDirectoryAndGetError(path_, &error)) {
    LOG(ERROR) << "[OWL] Failed to create data directory: " << path_.value()
               << " error=" << static_cast<int>(error);
  } else {
    // Ensure permissions are 0700 even if the directory already existed.
    chmod(path_.value().c_str(), 0700);
  }

  // Initialize PermissionManager. Off-the-record mode uses empty path
  // (memory-only, no file persistence).
  base::FilePath permissions_path;
  if (!off_the_record_) {
    permissions_path = path_.AppendASCII("permissions.json");
  }
  permission_manager_ =
      std::make_unique<OWLPermissionManager>(permissions_path);
  ssl_host_state_delegate_ = std::make_unique<OWLSSLHostStateDelegate>();
}

OWLContentBrowserContext::~OWLContentBrowserContext() {
  NotifyWillBeDestroyed();
  // Shutdown download service before storage partitions. The service holds
  // per-item observers that reference DownloadItems owned by DownloadManager.
  // These must be removed before DownloadManager::Shutdown() destroys items.
  if (download_service_) {
    download_service_->Shutdown();
  }
  // ShutdownStoragePartitions() triggers DownloadManager::Shutdown() which
  // calls our delegate's Shutdown(). The delegate must outlive this call.
  ShutdownStoragePartitions();
  download_manager_delegate_.reset();
  download_service_.reset();
}

base::FilePath OWLContentBrowserContext::GetPath() const {
  return path_;
}

bool OWLContentBrowserContext::IsOffTheRecord() {
  return off_the_record_;
}

std::unique_ptr<content::ZoomLevelDelegate>
OWLContentBrowserContext::CreateZoomLevelDelegate(
    const base::FilePath& /*partition_path*/) {
  return nullptr;
}

content::DownloadManagerDelegate*
OWLContentBrowserContext::GetDownloadManagerDelegate() {
  if (!download_manager_delegate_) {
    download_manager_delegate_ = std::make_unique<OWLDownloadManagerDelegate>();
    download_manager_delegate_->SetDownloadManager(GetDownloadManager());

    // Create the service layer and connect it to the delegate so that
    // OnDownloadCreated() notifications flow through to OWLDownloadService.
    download_service_ =
        std::make_unique<OWLDownloadService>(download_manager_delegate_.get());
    download_manager_delegate_->SetDownloadService(download_service_.get());
  }
  return download_manager_delegate_.get();
}

content::BrowserPluginGuestManager*
OWLContentBrowserContext::GetGuestManager() {
  return nullptr;
}

storage::SpecialStoragePolicy*
OWLContentBrowserContext::GetSpecialStoragePolicy() {
  return nullptr;
}

content::PlatformNotificationService*
OWLContentBrowserContext::GetPlatformNotificationService() {
  return nullptr;
}

content::PushMessagingService*
OWLContentBrowserContext::GetPushMessagingService() {
  return nullptr;
}

content::StorageNotificationService*
OWLContentBrowserContext::GetStorageNotificationService() {
  return nullptr;
}

content::SSLHostStateDelegate*
OWLContentBrowserContext::GetSSLHostStateDelegate() {
  return ssl_host_state_delegate_.get();
}

content::PermissionControllerDelegate*
OWLContentBrowserContext::GetPermissionControllerDelegate() {
  return permission_manager_.get();
}

content::ReduceAcceptLanguageControllerDelegate*
OWLContentBrowserContext::GetReduceAcceptLanguageControllerDelegate() {
  return nullptr;
}

content::ClientHintsControllerDelegate*
OWLContentBrowserContext::GetClientHintsControllerDelegate() {
  return nullptr;
}

content::BackgroundFetchDelegate*
OWLContentBrowserContext::GetBackgroundFetchDelegate() {
  return nullptr;
}

content::BackgroundSyncController*
OWLContentBrowserContext::GetBackgroundSyncController() {
  return nullptr;
}

content::BrowsingDataRemoverDelegate*
OWLContentBrowserContext::GetBrowsingDataRemoverDelegate() {
  return nullptr;
}

}  // namespace owl
