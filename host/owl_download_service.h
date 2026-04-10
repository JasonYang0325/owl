// Copyright 2026 AntlerAI. All rights reserved.

#ifndef THIRD_PARTY_OWL_HOST_OWL_DOWNLOAD_SERVICE_H_
#define THIRD_PARTY_OWL_HOST_OWL_DOWNLOAD_SERVICE_H_

#include <cstdint>
#include <set>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/sequence_checker.h"
#include "components/download/public/common/download_item.h"

namespace owl {

class OWLDownloadManagerDelegate;

// Business-layer service for download management. Maintains per-item
// observers and provides query/operation APIs. Modeled after
// OWLHistoryService (independent of Chromium delegate).
// Must be created and used on the UI sequence.
class OWLDownloadService : public download::DownloadItem::Observer {
 public:
  explicit OWLDownloadService(OWLDownloadManagerDelegate* delegate);
  ~OWLDownloadService() override;

  OWLDownloadService(const OWLDownloadService&) = delete;
  OWLDownloadService& operator=(const OWLDownloadService&) = delete;

  // Must be called before destruction to remove all item observers.
  void Shutdown();

  // --- Query ---

  // Returns all download items currently tracked via OnNewDownload()
  // (i.e. from observed_items_).
  std::vector<download::DownloadItem*> GetAllDownloads();

  // Finds a download item by its ID. Returns nullptr if not found.
  download::DownloadItem* FindById(uint32_t id);

  // --- Operations ---

  void PauseDownload(uint32_t id);
  void ResumeDownload(uint32_t id);
  void CancelDownload(uint32_t id);
  void RemoveEntry(uint32_t id);
  void OpenFile(uint32_t id);      // NOTIMPLEMENTED in Phase 1
  void ShowInFolder(uint32_t id);  // NOTIMPLEMENTED in Phase 1

  // Called by OWLDownloadManagerDelegate::OnDownloadCreated() to register
  // a per-item observer on a newly created download.
  void OnNewDownload(download::DownloadItem* item);

  // --- Callbacks ---

  // Notifies when a download changes. |created| is true for new downloads.
  using DownloadChangedCallback =
      base::RepeatingCallback<void(download::DownloadItem* item, bool created)>;
  void SetChangedCallback(DownloadChangedCallback callback);

  // Notifies when a download is destroyed/removed.
  using DownloadRemovedCallback =
      base::RepeatingCallback<void(uint32_t download_id)>;
  void SetRemovedCallback(DownloadRemovedCallback callback);

  // download::DownloadItem::Observer:
  void OnDownloadUpdated(download::DownloadItem* item) override;
  void OnDownloadDestroyed(download::DownloadItem* item) override;

 private:
  raw_ptr<OWLDownloadManagerDelegate> delegate_;
  DownloadChangedCallback changed_callback_;
  DownloadRemovedCallback removed_callback_;
  std::set<raw_ptr<download::DownloadItem, SetExperimental>> observed_items_;

  SEQUENCE_CHECKER(ui_sequence_checker_);
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_DOWNLOAD_SERVICE_H_
