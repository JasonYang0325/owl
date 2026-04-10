// Copyright 2026 AntlerAI. All rights reserved.
// Minimal content::BrowserContext for OWL Host.

#ifndef THIRD_PARTY_OWL_HOST_OWL_CONTENT_BROWSER_CONTEXT_H_
#define THIRD_PARTY_OWL_HOST_OWL_CONTENT_BROWSER_CONTEXT_H_

#include <memory>

#include "base/files/file_path.h"
#include "content/public/browser/browser_context.h"
#include "third_party/owl/host/owl_download_manager_delegate.h"
#include "third_party/owl/host/owl_download_service.h"
#include "third_party/owl/host/owl_permission_manager.h"
#include "third_party/owl/host/owl_ssl_host_state_delegate.h"

namespace owl {

// Minimal BrowserContext that provides just enough for content::WebContents
// to load web pages. Most delegates return nullptr (use defaults).
class OWLContentBrowserContext : public content::BrowserContext {
 public:
  explicit OWLContentBrowserContext(bool off_the_record);
  ~OWLContentBrowserContext() override;

  // content::BrowserContext:
  base::FilePath GetPath() const override;
  bool IsOffTheRecord() override;
  std::unique_ptr<content::ZoomLevelDelegate> CreateZoomLevelDelegate(
      const base::FilePath& partition_path) override;
  content::DownloadManagerDelegate* GetDownloadManagerDelegate() override;
  content::BrowserPluginGuestManager* GetGuestManager() override;
  storage::SpecialStoragePolicy* GetSpecialStoragePolicy() override;
  content::PlatformNotificationService*
      GetPlatformNotificationService() override;
  content::PushMessagingService* GetPushMessagingService() override;
  content::StorageNotificationService*
      GetStorageNotificationService() override;
  content::SSLHostStateDelegate* GetSSLHostStateDelegate() override;
  content::PermissionControllerDelegate*
      GetPermissionControllerDelegate() override;
  content::ReduceAcceptLanguageControllerDelegate*
      GetReduceAcceptLanguageControllerDelegate() override;
  content::ClientHintsControllerDelegate*
      GetClientHintsControllerDelegate() override;
  content::BackgroundFetchDelegate* GetBackgroundFetchDelegate() override;
  content::BackgroundSyncController* GetBackgroundSyncController() override;
  content::BrowsingDataRemoverDelegate*
      GetBrowsingDataRemoverDelegate() override;

  // Public accessor for OWLDownloadService (used by OWLBrowserContext).
  // Returns nullptr if GetDownloadManagerDelegate() has not been called yet.
  OWLDownloadService* download_service() { return download_service_.get(); }

  // Public accessor for OWLPermissionManager (used by OWLBrowserImpl
  // for injection into OWLBrowserContext).
  OWLPermissionManager* GetPermissionManager() {
    return permission_manager_.get();
  }

 private:
  base::FilePath path_;
  bool off_the_record_;
  std::unique_ptr<OWLDownloadManagerDelegate> download_manager_delegate_;
  std::unique_ptr<OWLDownloadService> download_service_;
  std::unique_ptr<OWLPermissionManager> permission_manager_;
  std::unique_ptr<OWLSSLHostStateDelegate> ssl_host_state_delegate_;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_CONTENT_BROWSER_CONTEXT_H_
