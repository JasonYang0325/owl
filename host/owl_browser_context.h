// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_HOST_OWL_BROWSER_CONTEXT_H_
#define THIRD_PARTY_OWL_HOST_OWL_BROWSER_CONTEXT_H_

#include <cstdint>
#include <map>
#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "third_party/owl/mojom/browser_context.mojom.h"
#include "third_party/owl/mojom/downloads.mojom.h"
#include "third_party/owl/mojom/history.mojom.h"
#include "third_party/owl/mojom/storage.mojom.h"

namespace download {
class DownloadItem;
}  // namespace download

namespace owl {

class DownloadServiceMojoAdapter;
class HistoryServiceMojoAdapter;
class OWLBookmarkService;
class OWLDownloadService;
class OWLHistoryService;
class OWLPermissionManager;
class OWLPermissionServiceImpl;
class OWLStorageService;
class OWLWebContents;

// Implements owl.mojom.BrowserContextHost.
// All methods run on the UI thread.
class OWLBrowserContext : public owl::mojom::BrowserContextHost {
 public:
  using DestroyedCallback = base::OnceCallback<void(OWLBrowserContext*)>;

  OWLBrowserContext(const std::string& partition_name,
                    bool off_the_record,
                    const base::FilePath& user_data_dir,
                    OWLPermissionManager* permission_manager,
                    OWLDownloadService* download_service,
                    DestroyedCallback destroyed_callback);

  // Convenience overload for tests (no permission_manager/download_service).
  OWLBrowserContext(const std::string& partition_name,
                    bool off_the_record,
                    const base::FilePath& user_data_dir,
                    DestroyedCallback destroyed_callback);

  ~OWLBrowserContext() override;

  OWLBrowserContext(const OWLBrowserContext&) = delete;
  OWLBrowserContext& operator=(const OWLBrowserContext&) = delete;

  // Binds this implementation to a Mojo receiver.
  void Bind(mojo::PendingReceiver<owl::mojom::BrowserContextHost> receiver);

  // owl::mojom::BrowserContextHost:
  void CreateWebView(
      mojo::PendingRemote<owl::mojom::WebViewObserver> observer,
      CreateWebViewCallback callback) override;
  void GetBookmarkService(GetBookmarkServiceCallback callback) override;
  void GetHistoryService(GetHistoryServiceCallback callback) override;
  void GetPermissionService(GetPermissionServiceCallback callback) override;
  void GetDownloadService(GetDownloadServiceCallback callback) override;
  void GetStorageService(GetStorageServiceCallback callback) override;
  void SetDownloadObserver(
      mojo::PendingRemote<owl::mojom::DownloadObserver> observer) override;
  void Destroy(DestroyCallback callback) override;

  // Returns the history service, lazily creating it on first call.
  // The returned pointer is owned by this BrowserContext.
  OWLHistoryService* GetHistoryServiceRaw();

  // Bind a history observer remote (called by HistoryServiceMojoAdapter).
  void SetHistoryObserver(
      mojo::PendingRemote<owl::mojom::HistoryObserver> observer);

  // Idempotent internal cleanup. Called by Destroy(), OnDisconnect(),
  // ~OWLBrowserContext(), and OWLBrowserImpl::Shutdown().
  // Triggers destroyed_callback_ (if set) at the end of cleanup.
  void DestroyInternal();

  // Inject a download service after construction (for testing).
  void SetDownloadService(OWLDownloadService* service);

  // For testing.
  const std::string& partition_name() const { return partition_name_; }
  bool off_the_record() const { return off_the_record_; }
  size_t web_view_count() const { return web_view_map_.size(); }

 private:
  void OnWebViewClosed(OWLWebContents* web_contents);
  void OnDisconnect();
  void OnHistoryChanged(const std::string& url);
  void OnDownloadChanged(download::DownloadItem* item, bool created);
  void OnDownloadRemoved(uint32_t download_id);

  const std::string partition_name_;
  const bool off_the_record_;
  const base::FilePath user_data_dir_;
  DestroyedCallback destroyed_callback_;

  // Idempotent guard for DestroyInternal().
  bool destroyed_ = false;

  mojo::Receiver<owl::mojom::BrowserContextHost> receiver_{this};

  // Monotonically increasing ID for WebView allocation.
  uint64_t next_webview_id_ = 1;

  // WebView instances keyed by webview_id (replaces former vector).
  std::map<uint64_t, std::unique_ptr<OWLWebContents>> web_view_map_;

  // Lazy-created bookmark service.
  std::unique_ptr<OWLBookmarkService> bookmark_service_;

  // Lazy-created history service.
  std::unique_ptr<OWLHistoryService> history_service_;

  // Mojo adapter for HistoryService (bridges Mojo IPC to OWLHistoryService).
  // Defined in owl_browser_context.cc.
  std::unique_ptr<HistoryServiceMojoAdapter> history_mojo_adapter_;

  // History observer remote (pushed from bridge via SetObserver).
  mojo::Remote<owl::mojom::HistoryObserver> history_observer_;

  // Permission manager (non-owning, owned by OWLContentBrowserContext).
  // May point to fallback_permission_manager_ when no external manager was
  // injected.
  raw_ptr<OWLPermissionManager> permission_manager_ = nullptr;

  // Memory-only fallback created when no external PermissionManager is
  // available, ensuring the non-nullable Mojom contract is satisfied.
  std::unique_ptr<OWLPermissionManager> fallback_permission_manager_;

  // Mojo adapter for PermissionService (bridges Mojo IPC to OWLPermissionManager).
  // Defined in owl_browser_context.cc.
  std::unique_ptr<OWLPermissionServiceImpl> permission_mojo_adapter_;

  // Lazy-created storage service.
  std::unique_ptr<OWLStorageService> storage_service_;

  // Download service pointer (not owned — owned by OWLContentBrowserContext).
  raw_ptr<OWLDownloadService> download_service_ = nullptr;

  // Mojo adapter for DownloadService (bridges Mojo IPC to OWLDownloadService).
  // Defined in owl_browser_context.cc.
  std::unique_ptr<DownloadServiceMojoAdapter> download_mojo_adapter_;

  // Download observer remote (pushed from bridge via SetDownloadObserver).
  mojo::Remote<owl::mojom::DownloadObserver> download_observer_;

  // Must be last member.
  base::WeakPtrFactory<OWLBrowserContext> weak_factory_{this};
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_BROWSER_CONTEXT_H_
