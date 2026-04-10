// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_download_service.h"

#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_target_info.h"
#include "components/download/public/common/mock_download_item.h"
#include "content/public/test/mock_download_manager.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_download_manager_delegate.h"
#include "url/gurl.h"

namespace owl {
namespace {

using ::testing::_;
using ::testing::DoAll;
using ::testing::NiceMock;
using ::testing::Return;
using ::testing::ReturnRef;
using ::testing::SetArgPointee;

// =============================================================================
// OWLDownloadManagerDelegate tests
// =============================================================================

class OWLDownloadDelegateTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    delegate_ = std::make_unique<OWLDownloadManagerDelegate>();
    mock_manager_ = std::make_unique<NiceMock<content::MockDownloadManager>>();
    delegate_->SetDownloadManager(mock_manager_.get());
  }

  void TearDown() override {
    delegate_->Shutdown();
    delegate_.reset();
    mock_manager_.reset();
  }

  base::test::TaskEnvironment task_environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
  base::ScopedTempDir temp_dir_;
  std::unique_ptr<OWLDownloadManagerDelegate> delegate_;
  std::unique_ptr<NiceMock<content::MockDownloadManager>> mock_manager_;
};

// AC-001: GetNextId returns monotonically increasing IDs.
// Verifies: GetNextId self-increment (技术方案 §3: next_id_ = 1, auto-incr)
TEST_F(OWLDownloadDelegateTest, GetNextId_Increments) {
  uint32_t first_id = 0;
  uint32_t second_id = 0;

  delegate_->GetNextId(
      base::BindOnce([](uint32_t* out, uint32_t id) { *out = id; },
                     &first_id));
  delegate_->GetNextId(
      base::BindOnce([](uint32_t* out, uint32_t id) { *out = id; },
                     &second_id));

  EXPECT_GT(first_id, 0u);
  EXPECT_EQ(second_id, first_id + 1);
}

// AC-001: DetermineDownloadTarget uses Content-Disposition filename when both
// Content-Disposition and suggested_filename are provided — Content-Disposition
// takes priority.
// Verifies: DetermineDownloadTarget → ComputeTargetPathOnFileThread full chain
// with Content-Disposition priority (技术方案 §4)
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_ContentDispositionPriority) {
  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  GURL url("https://example.com/report.pdf");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition())
      .WillByDefault(Return("attachment; filename=\"annual-report.pdf\""));
  // Even with a suggested filename, Content-Disposition should win.
  ON_CALL(*mock_item, GetSuggestedFilename())
      .WillByDefault(Return("suggested-name.pdf"));
  ON_CALL(*mock_item, GetMimeType())
      .WillByDefault(Return("application/pdf"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  bool handled =
      delegate_->DetermineDownloadTarget(mock_item.get(), &callback);
  EXPECT_TRUE(handled);

  task_environment_.RunUntilIdle();

  ASSERT_TRUE(callback_invoked);
  EXPECT_FALSE(received_info.target_path.empty());
  // Content-Disposition filename takes priority over URL-derived name.
  EXPECT_EQ(received_info.target_path.BaseName().value(),
            "annual-report.pdf");
  EXPECT_EQ(received_info.target_path.DirName().BaseName().value(),
            "Downloads");
}

// AC-001: DetermineDownloadTarget falls back to URL-derived filename when
// Content-Disposition is absent — verifies .pptx extension from URL path.
// Verifies: DetermineDownloadTarget → ComputeTargetPathOnFileThread URL
// fallback path (技术方案 §4)
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_UrlFallbackPptx) {
  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  GURL url("https://example.com/slides.pptx");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetSuggestedFilename()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetMimeType())
      .WillByDefault(Return("application/vnd.openxmlformats-officedocument."
                            "presentationml.presentation"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  delegate_->DetermineDownloadTarget(mock_item.get(), &callback);
  task_environment_.RunUntilIdle();

  ASSERT_TRUE(callback_invoked);
  EXPECT_FALSE(received_info.target_path.empty());
  EXPECT_EQ(received_info.target_path.BaseName().value(), "slides.pptx");
}

// AC-001: DetermineDownloadTarget uses "download" as default filename when
// URL path has no filename component and Content-Disposition is absent.
// Verifies: DetermineDownloadTarget → ComputeTargetPathOnFileThread default
// name fallback (技术方案 §4)
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_DefaultName) {
  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  // URL with no filename component — just a root path.
  GURL url("https://example.com/");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetSuggestedFilename()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetMimeType())
      .WillByDefault(Return("application/octet-stream"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  delegate_->DetermineDownloadTarget(mock_item.get(), &callback);
  task_environment_.RunUntilIdle();

  ASSERT_TRUE(callback_invoked);
  EXPECT_FALSE(received_info.target_path.empty());
  // Default name "download" should appear in the generated filename.
  EXPECT_THAT(received_info.target_path.BaseName().value(),
              ::testing::HasSubstr("download"));
  EXPECT_EQ(received_info.target_path.DirName().BaseName().value(),
            "Downloads");
}

// Subclass that overrides GetSaveDir to return a controlled temp directory,
// allowing tests to pre-create files and verify deduplication behavior.
class TempDirDownloadManagerDelegate : public OWLDownloadManagerDelegate {
 public:
  explicit TempDirDownloadManagerDelegate(const base::FilePath& dir)
      : dir_(dir) {}

  void GetSaveDir(content::BrowserContext* context,
                  base::FilePath* website_save_dir,
                  base::FilePath* download_save_dir) override {
    if (download_save_dir)
      *download_save_dir = dir_;
  }

 private:
  base::FilePath dir_;
};

// AC-001: DetermineDownloadTarget deduplicates filenames via
// base::GetUniquePath when a file with the same name already exists.
// Verifies: DetermineDownloadTarget → ComputeTargetPathOnFileThread →
// base::GetUniquePath full integration chain (技术方案 §4)
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_UniqueOnConflict) {
  // Use TempDirDownloadManagerDelegate so the download dir is our temp_dir_.
  auto temp_delegate = std::make_unique<TempDirDownloadManagerDelegate>(
      temp_dir_.GetPath());
  temp_delegate->SetDownloadManager(mock_manager_.get());

  // Pre-create a file to force a naming conflict.
  base::FilePath existing =
      temp_dir_.GetPath().AppendASCII("report.pdf");
  ASSERT_TRUE(base::WriteFile(existing, "existing content"));

  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  GURL url("https://example.com/report.pdf");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetSuggestedFilename()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetMimeType())
      .WillByDefault(Return("application/pdf"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  bool handled =
      temp_delegate->DetermineDownloadTarget(mock_item.get(), &callback);
  EXPECT_TRUE(handled);

  task_environment_.RunUntilIdle();

  ASSERT_TRUE(callback_invoked);
  EXPECT_FALSE(received_info.target_path.empty());
  // The target path must differ from the existing file (deduplicated).
  EXPECT_NE(received_info.target_path, existing);
  // But it should still be in the same directory.
  EXPECT_EQ(received_info.target_path.DirName(), existing.DirName());
  // The deduplicated path should not yet exist on disk.
  EXPECT_FALSE(base::PathExists(received_info.target_path));

  temp_delegate->Shutdown();
}

// AC-001: GetSaveDir returns a non-empty download directory.
// On macOS this should resolve to ~/Downloads.
// Verifies: GetSaveDir → base::apple::GetUserDirectory (技术方案 §4)
TEST_F(OWLDownloadDelegateTest, GetSaveDir_ReturnsDownloadsDir) {
  base::FilePath download_dir;
  delegate_->GetSaveDir(/*context=*/nullptr,
                        /*website_save_dir=*/nullptr,
                        &download_dir);

  EXPECT_FALSE(download_dir.empty());
  // On macOS, the path should end with "Downloads".
  EXPECT_EQ(download_dir.BaseName().value(), "Downloads");
}

// AC-001: DetermineDownloadTarget end-to-end — calls the async callback with
// a non-empty target path derived from the download item's metadata.
// Verifies: DetermineDownloadTarget → PostTask(ComputeTargetPathOnFileThread)
//           → callback(DownloadTargetInfo) full async chain (技术方案 §4)
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_AsyncCallbackChain) {
  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  // Set up the mock item to return realistic download metadata.
  GURL url("https://example.com/document.pdf");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition())
      .WillByDefault(Return("attachment; filename=\"quarterly-report.pdf\""));
  ON_CALL(*mock_item, GetSuggestedFilename()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetMimeType())
      .WillByDefault(Return("application/pdf"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  // Prepare the callback to capture the result.
  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  bool handled =
      delegate_->DetermineDownloadTarget(mock_item.get(), &callback);
  EXPECT_TRUE(handled);

  // The delegate posts ComputeTargetPathOnFileThread to a background runner,
  // then replies on the UI thread. Flush all pending tasks.
  task_environment_.RunUntilIdle();

  ASSERT_TRUE(callback_invoked);
  // The target path must be non-empty and end with the expected filename.
  EXPECT_FALSE(received_info.target_path.empty());
  EXPECT_EQ(received_info.target_path.BaseName().value(),
            "quarterly-report.pdf");
  // The file should be saved inside ~/Downloads (path ends with /Downloads/).
  EXPECT_EQ(received_info.target_path.DirName().BaseName().value(),
            "Downloads");

  // intermediate_path should use a .crdownload suffix during download.
  EXPECT_FALSE(received_info.intermediate_path.empty());
  EXPECT_EQ(received_info.intermediate_path.FinalExtension(), ".crdownload");

  // danger_type should be NOT_DANGEROUS for a normal HTTPS download.
  EXPECT_EQ(received_info.danger_type,
            download::DOWNLOAD_DANGER_TYPE_NOT_DANGEROUS);

  // target_disposition should be OVERWRITE (no user prompt in Phase 1).
  EXPECT_EQ(received_info.target_disposition,
            download::DownloadItem::TARGET_DISPOSITION_OVERWRITE);

  // interrupt_reason should be NONE — no error determining the target.
  EXPECT_EQ(received_info.interrupt_reason,
            download::DOWNLOAD_INTERRUPT_REASON_NONE);

  // insecure_download_status: HTTPS download is explicitly marked SAFE.
  EXPECT_EQ(received_info.insecure_download_status,
            download::DownloadItem::InsecureDownloadStatus::SAFE);
}

// AC-001: DetermineDownloadTarget falls back to URL-derived name when
// Content-Disposition is absent.
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_FallbackToUrl) {
  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  GURL url("https://cdn.example.com/assets/image.png");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetSuggestedFilename()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetMimeType()).WillByDefault(Return("image/png"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  delegate_->DetermineDownloadTarget(mock_item.get(), &callback);
  task_environment_.RunUntilIdle();

  ASSERT_TRUE(callback_invoked);
  EXPECT_FALSE(received_info.target_path.empty());
  // URL-derived filename should be "image.png".
  EXPECT_EQ(received_info.target_path.BaseName().value(), "image.png");

  // intermediate_path should use a .crdownload suffix during download.
  EXPECT_FALSE(received_info.intermediate_path.empty());
  EXPECT_EQ(received_info.intermediate_path.FinalExtension(), ".crdownload");

  // danger_type should be NOT_DANGEROUS for a normal HTTPS download.
  EXPECT_EQ(received_info.danger_type,
            download::DOWNLOAD_DANGER_TYPE_NOT_DANGEROUS);

  // target_disposition should be OVERWRITE (no user prompt in Phase 1).
  EXPECT_EQ(received_info.target_disposition,
            download::DownloadItem::TARGET_DISPOSITION_OVERWRITE);

  // interrupt_reason should be NONE — no error determining the target.
  EXPECT_EQ(received_info.interrupt_reason,
            download::DOWNLOAD_INTERRUPT_REASON_NONE);

  // insecure_download_status: HTTPS download is explicitly marked SAFE.
  EXPECT_EQ(received_info.insecure_download_status,
            download::DownloadItem::InsecureDownloadStatus::SAFE);
}

// =============================================================================
// OWLDownloadService tests
// =============================================================================

class OWLDownloadServiceTest : public testing::Test {
 protected:
  void SetUp() override {
    mock_manager_ = std::make_unique<NiceMock<content::MockDownloadManager>>();
    delegate_ = std::make_unique<OWLDownloadManagerDelegate>();
    delegate_->SetDownloadManager(mock_manager_.get());
    service_ = std::make_unique<OWLDownloadService>(delegate_.get());
    delegate_->SetDownloadService(service_.get());
  }

  void TearDown() override {
    service_->Shutdown();
    service_.reset();
    delegate_->Shutdown();
    delegate_.reset();
    mock_manager_.reset();
  }

  // Creates a NiceMock<download::MockDownloadItem> with a given ID.
  std::unique_ptr<NiceMock<download::MockDownloadItem>> CreateMockItem(
      uint32_t id) {
    auto item = std::make_unique<NiceMock<download::MockDownloadItem>>();
    ON_CALL(*item, GetId()).WillByDefault(Return(id));
    return item;
  }

  base::test::TaskEnvironment task_environment_;
  std::unique_ptr<NiceMock<content::MockDownloadManager>> mock_manager_;
  std::unique_ptr<OWLDownloadManagerDelegate> delegate_;
  std::unique_ptr<OWLDownloadService> service_;
};

// AC-001: OnNewDownload registers a per-item observer on the DownloadItem.
// Verifies: OWLDownloadService::OnNewDownload → item->AddObserver(this)
// (技术方案 §4: OnNewDownload 注册 observer)
TEST_F(OWLDownloadServiceTest, OnNewDownload_RegistersObserver) {
  auto item = CreateMockItem(1);

  service_->OnNewDownload(item.get());

  // Verify item is tracked in observed_items_ via GetAllDownloads.
  auto downloads = service_->GetAllDownloads();
  ASSERT_EQ(downloads.size(), 1u);
  EXPECT_EQ(downloads[0]->GetId(), 1u);

  // Verify observer was actually registered by checking that
  // NotifyObserversDownloadUpdated reaches the service's OnDownloadUpdated.
  bool update_received = false;
  service_->SetChangedCallback(base::BindRepeating(
      [](bool* received, download::DownloadItem*, bool) {
        *received = true;
      },
      &update_received));
  item->NotifyObserversDownloadUpdated();
  EXPECT_TRUE(update_received);
}

// AC-001: OnNewDownload triggers the changed callback with created=true.
// Verifies: OnNewDownload → changed_callback_.Run(item, true)
TEST_F(OWLDownloadServiceTest, OnNewDownload_TriggersCallback) {
  bool callback_called = false;
  bool was_created = false;
  service_->SetChangedCallback(base::BindRepeating(
      [](bool* called, bool* created, download::DownloadItem* item,
         bool is_created) {
        *called = true;
        *created = is_created;
      },
      &callback_called, &was_created));

  auto item = CreateMockItem(1);
  service_->OnNewDownload(item.get());

  EXPECT_TRUE(callback_called);
  EXPECT_TRUE(was_created);
}

// AC-001: OnDownloadDestroyed removes the observer and cleans up tracking.
// Verifies: OWLDownloadService::OnDownloadDestroyed
// (技术方案 §4: item->RemoveObserver + observed_items_.erase)
TEST_F(OWLDownloadServiceTest, OnDownloadDestroyed_RemovesObserver) {
  auto item = CreateMockItem(42);

  service_->OnNewDownload(item.get());
  ASSERT_EQ(service_->GetAllDownloads().size(), 1u);

  // Simulate DownloadItem destruction — the mock's destructor calls
  // OnDownloadDestroyed on all registered observers.
  item.reset();

  EXPECT_TRUE(service_->GetAllDownloads().empty());
}

// AC-001: Shutdown removes observers from all tracked items without crashing.
// Verifies: OWLDownloadService::Shutdown
// (技术方案 §4: for item : observed_items_ → RemoveObserver + clear)
TEST_F(OWLDownloadServiceTest, Shutdown_RemovesAllObservers) {
  auto item1 = CreateMockItem(1);
  auto item2 = CreateMockItem(2);
  auto item3 = CreateMockItem(3);

  service_->OnNewDownload(item1.get());
  service_->OnNewDownload(item2.get());
  service_->OnNewDownload(item3.get());
  ASSERT_EQ(service_->GetAllDownloads().size(), 3u);

  service_->Shutdown();

  // After shutdown, destroying items should not crash (observers removed).
  item1.reset();
  item2.reset();
  item3.reset();

  // GetAllDownloads should be empty after shutdown.
  EXPECT_TRUE(service_->GetAllDownloads().empty());
}

// AC-001: PauseDownload calls DownloadItem::Pause().
// Verifies: OWLDownloadService::PauseDownload (技术方案 §2: Mojom Pause)
TEST_F(OWLDownloadServiceTest, PauseDownload) {
  auto item = CreateMockItem(10);
  EXPECT_CALL(*item, Pause()).Times(1);

  service_->OnNewDownload(item.get());
  service_->PauseDownload(10);
}

// AC-001: PauseDownload with non-existent ID does not crash.
TEST_F(OWLDownloadServiceTest, PauseDownload_InvalidId) {
  // Should not crash when called with unknown ID.
  service_->PauseDownload(999);
}

// AC-001: ResumeDownload calls DownloadItem::Resume(true).
// Verifies: OWLDownloadService::ResumeDownload (技术方案 §2: Mojom Resume)
TEST_F(OWLDownloadServiceTest, ResumeDownload) {
  auto item = CreateMockItem(20);
  EXPECT_CALL(*item, Resume(/*user_resume=*/true)).Times(1);

  service_->OnNewDownload(item.get());
  service_->ResumeDownload(20);
}

// AC-001: ResumeDownload with non-existent ID does not crash.
TEST_F(OWLDownloadServiceTest, ResumeDownload_InvalidId) {
  service_->ResumeDownload(999);
}

// AC-001: CancelDownload calls DownloadItem::Cancel(true).
// Verifies: OWLDownloadService::CancelDownload (技术方案 §2: Mojom Cancel)
TEST_F(OWLDownloadServiceTest, CancelDownload) {
  auto item = CreateMockItem(30);
  EXPECT_CALL(*item, Cancel(/*user_cancel=*/true)).Times(1);

  service_->OnNewDownload(item.get());
  service_->CancelDownload(30);
}

// AC-001: CancelDownload with non-existent ID does not crash.
TEST_F(OWLDownloadServiceTest, CancelDownload_InvalidId) {
  service_->CancelDownload(999);
}

// AC-001: GetAllDownloads returns all registered items.
// Verifies: OWLDownloadService::GetAllDownloads
// (技术方案 §3: observed_items_ tracking)
TEST_F(OWLDownloadServiceTest, GetAllDownloads) {
  auto item1 = CreateMockItem(1);
  auto item2 = CreateMockItem(2);

  service_->OnNewDownload(item1.get());
  service_->OnNewDownload(item2.get());

  auto downloads = service_->GetAllDownloads();
  ASSERT_EQ(downloads.size(), 2u);
}

// AC-001: GetAllDownloads returns empty when no downloads registered.
TEST_F(OWLDownloadServiceTest, GetAllDownloads_Empty) {
  auto downloads = service_->GetAllDownloads();
  EXPECT_TRUE(downloads.empty());
}

// AC-001: FindById returns the correct item.
// Verifies: OWLDownloadService::FindById
TEST_F(OWLDownloadServiceTest, FindById) {
  auto item1 = CreateMockItem(10);
  auto item2 = CreateMockItem(20);

  service_->OnNewDownload(item1.get());
  service_->OnNewDownload(item2.get());

  download::DownloadItem* found = service_->FindById(20);
  ASSERT_NE(found, nullptr);
  EXPECT_EQ(found->GetId(), 20u);
}

// AC-001: FindById returns nullptr for non-existent ID.
TEST_F(OWLDownloadServiceTest, FindById_NotFound) {
  auto item = CreateMockItem(1);
  service_->OnNewDownload(item.get());

  EXPECT_EQ(service_->FindById(999), nullptr);
}

// AC-001: OnDownloadUpdated triggers the changed callback with created=false.
// Verifies: OWLDownloadService::OnDownloadUpdated
// (技术方案 §4: changed_callback_.Run(item, false))
TEST_F(OWLDownloadServiceTest, OnDownloadUpdated_TriggersCallback) {
  auto item = CreateMockItem(1);
  service_->OnNewDownload(item.get());

  bool update_received = false;
  bool was_created = true;
  service_->SetChangedCallback(base::BindRepeating(
      [](bool* received, bool* created, download::DownloadItem*,
         bool is_created) {
        *received = true;
        *created = is_created;
      },
      &update_received, &was_created));

  // Simulate a download update notification from the mock.
  item->NotifyObserversDownloadUpdated();

  EXPECT_TRUE(update_received);
  EXPECT_FALSE(was_created);
}

// AC-001: Multiple downloads can be registered and independently destroyed.
// Verifies: observer bookkeeping does not corrupt on partial destruction.
TEST_F(OWLDownloadServiceTest, MultipleDownloads_IndependentLifecycle) {
  auto item1 = CreateMockItem(1);
  auto item2 = CreateMockItem(2);
  auto item3 = CreateMockItem(3);

  service_->OnNewDownload(item1.get());
  service_->OnNewDownload(item2.get());
  service_->OnNewDownload(item3.get());
  ASSERT_EQ(service_->GetAllDownloads().size(), 3u);

  // Destroy middle item.
  item2.reset();
  EXPECT_EQ(service_->GetAllDownloads().size(), 2u);

  // Remaining items should still be findable.
  EXPECT_NE(service_->FindById(1), nullptr);
  EXPECT_EQ(service_->FindById(2), nullptr);
  EXPECT_NE(service_->FindById(3), nullptr);

  // Destroy first item.
  item1.reset();
  EXPECT_EQ(service_->GetAllDownloads().size(), 1u);
}

// AC-001: RemoveEntry calls DownloadItem::Remove().
// Verifies: OWLDownloadService::RemoveEntry (技术方案 §2: Mojom RemoveEntry)
TEST_F(OWLDownloadServiceTest, RemoveEntry) {
  auto item = CreateMockItem(50);
  EXPECT_CALL(*item, Remove()).Times(1);

  service_->OnNewDownload(item.get());
  service_->RemoveEntry(50);
}

// AC-001: RemoveEntry with non-existent ID does not crash.
TEST_F(OWLDownloadServiceTest, RemoveEntry_InvalidId) {
  service_->RemoveEntry(999);
}

// AC-001: OnDownloadDestroyed triggers the removed callback with the correct
// download ID.
// Verifies: OWLDownloadService::OnDownloadDestroyed → removed_callback_
TEST_F(OWLDownloadServiceTest, OnDownloadDestroyed_TriggersRemovedCallback) {
  auto item = CreateMockItem(77);
  service_->OnNewDownload(item.get());

  uint32_t removed_id = 0;
  bool callback_called = false;
  service_->SetRemovedCallback(base::BindRepeating(
      [](bool* called, uint32_t* out_id, uint32_t id) {
        *called = true;
        *out_id = id;
      },
      &callback_called, &removed_id));

  // Destroying the mock item triggers OnDownloadDestroyed on all observers.
  item.reset();

  EXPECT_TRUE(callback_called);
  EXPECT_EQ(removed_id, 77u);
}

// AC-001: OnDownloadCreated on the delegate forwards to
// OWLDownloadService::OnNewDownload.
// Verifies: delegate → service integration (技术方案 §4: OnDownloadCreated
// calls service_->OnNewDownload)
TEST_F(OWLDownloadServiceTest, DelegateOnDownloadCreated_ForwardsToService) {
  auto item = CreateMockItem(99);

  bool callback_called = false;
  bool was_created = false;
  service_->SetChangedCallback(base::BindRepeating(
      [](bool* called, bool* created, download::DownloadItem*,
         bool is_created) {
        *called = true;
        *created = is_created;
      },
      &callback_called, &was_created));

  // Simulate what the DownloadManager does: call OnDownloadCreated on the
  // delegate, which should forward to service_->OnNewDownload().
  delegate_->OnDownloadCreated(mock_manager_.get(), item.get());

  EXPECT_TRUE(callback_called);
  EXPECT_TRUE(was_created);
  // The item should now be tracked by the service.
  EXPECT_NE(service_->FindById(99), nullptr);
}

// =============================================================================
// GAN Round 2 — supplementary tests
// =============================================================================

// Regression: GetQuarantineConnectionCallback returns an empty (null) callback.
// Verifies: OWLDownloadManagerDelegate::GetQuarantineConnectionCallback
// returns a default-constructed callback (Phase 1 stub).
TEST_F(OWLDownloadDelegateTest, GetQuarantineConnectionCallback_ReturnsEmpty) {
  auto cb = delegate_->GetQuarantineConnectionCallback();
  // The callback should be null/empty — quarantine is not wired in Phase 1.
  EXPECT_TRUE(cb.is_null());
}

// ManagerGoingDown clears the delegate's download_manager_ pointer.
// Verifies: OWLDownloadManagerDelegate::ManagerGoingDown nullifies state.
TEST_F(OWLDownloadDelegateTest, ManagerGoingDown_ClearsManager) {
  // Precondition: manager is set.
  ASSERT_NE(delegate_->download_manager(), nullptr);

  delegate_->ManagerGoingDown(mock_manager_.get());

  // After ManagerGoingDown, the delegate should no longer hold the manager.
  EXPECT_EQ(delegate_->download_manager(), nullptr);
}

// OpenFile and ShowInFolder are NOTIMPLEMENTED stubs — must not crash.
// Verifies: OWLDownloadService::OpenFile / ShowInFolder (技术方案 §2: Phase 1 stub)
TEST_F(OWLDownloadServiceTest, OpenFileAndShowInFolder_DoNotCrash) {
  auto item = CreateMockItem(60);
  service_->OnNewDownload(item.get());

  // Calling NOTIMPLEMENTED stubs with a valid ID must not crash.
  service_->OpenFile(60);
  service_->ShowInFolder(60);

  // Also safe with non-existent IDs.
  service_->OpenFile(999);
  service_->ShowInFolder(999);
}

// Subclass that overrides GetSaveDir to return an empty download directory,
// simulating a misconfigured system where no download dir is available.
class EmptyDirDownloadManagerDelegate : public OWLDownloadManagerDelegate {
 public:
  void GetSaveDir(content::BrowserContext* context,
                  base::FilePath* website_save_dir,
                  base::FilePath* download_save_dir) override {
    // Return empty paths to exercise the empty-dir early-return guard.
    if (website_save_dir)
      *website_save_dir = base::FilePath();
    if (download_save_dir)
      *download_save_dir = base::FilePath();
  }
};

// DetermineDownloadTarget handles an empty download directory gracefully:
// either returns false (declining to handle), or returns true with an empty
// target_path. Verifies the early-return guard when GetSaveDir yields empty.
TEST_F(OWLDownloadDelegateTest, DetermineDownloadTarget_EmptyDirEarlyReturn) {
  // Create a delegate with GetSaveDir overridden to return empty paths.
  auto empty_dir_delegate = std::make_unique<EmptyDirDownloadManagerDelegate>();
  empty_dir_delegate->SetDownloadManager(mock_manager_.get());

  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  GURL url("https://example.com/file.zip");
  std::vector<GURL> url_chain = {url};
  ON_CALL(*mock_item, GetURL()).WillByDefault(ReturnRef(url));
  ON_CALL(*mock_item, GetUrlChain()).WillByDefault(ReturnRef(url_chain));
  ON_CALL(*mock_item, GetContentDisposition()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetSuggestedFilename()).WillByDefault(Return(""));
  ON_CALL(*mock_item, GetMimeType())
      .WillByDefault(Return("application/octet-stream"));
  base::FilePath forced_path;
  ON_CALL(*mock_item, GetForcedFilePath())
      .WillByDefault(ReturnRef(forced_path));

  bool callback_invoked = false;
  download::DownloadTargetInfo received_info;
  download::DownloadTargetCallback callback = base::BindOnce(
      [](bool* invoked, download::DownloadTargetInfo* out,
         download::DownloadTargetInfo info) {
        *invoked = true;
        *out = std::move(info);
      },
      &callback_invoked, &received_info);

  bool handled =
      empty_dir_delegate->DetermineDownloadTarget(mock_item.get(), &callback);

  // Flush any posted tasks.
  task_environment_.RunUntilIdle();

  // When save dir is empty, one of two acceptable behaviors:
  // (a) DetermineDownloadTarget returns false — delegate declines to handle,
  //     callback is NOT consumed/invoked.
  // (b) Returns true — delegate handled it, but callback delivers an empty
  //     target_path indicating no valid save location.
  // Either way, no non-empty target_path should be produced.
  if (!handled) {
    EXPECT_FALSE(callback_invoked)
        << "When returning false, the callback must not be consumed";
  } else {
    ASSERT_TRUE(callback_invoked)
        << "When returning true, the callback must be invoked";
    EXPECT_TRUE(received_info.target_path.empty())
        << "With empty save dir, target_path must be empty";
  }

  empty_dir_delegate->Shutdown();
}

// =============================================================================
// GAN Round 3 — residual minor improvements
// =============================================================================

// ShouldCompleteDownload returns true (no quarantine gate in Phase 1).
// Verifies: OWLDownloadManagerDelegate::ShouldCompleteDownload always allows
// completion without deferring via the complete_callback.
TEST_F(OWLDownloadDelegateTest, ShouldCompleteDownload_ReturnsTrue) {
  auto mock_item = std::make_unique<NiceMock<download::MockDownloadItem>>();

  bool closure_ran = false;
  base::OnceClosure complete_callback = base::BindOnce(
      [](bool* ran) { *ran = true; }, &closure_ran);

  bool result =
      delegate_->ShouldCompleteDownload(mock_item.get(),
                                        std::move(complete_callback));

  // ShouldCompleteDownload should return true synchronously (download proceeds
  // immediately). The complete_callback should NOT have been consumed/run
  // because completion is not deferred.
  EXPECT_TRUE(result);
  EXPECT_FALSE(closure_ran);
}

// OnNewDownload called twice with the same item should not double-register
// the observer. Verifies that the changed callback fires exactly once per
// update notification, even after duplicate OnNewDownload calls.
// Also verifies the second OnNewDownload does not re-fire created=true.
TEST_F(OWLDownloadServiceTest, OnNewDownload_DuplicateDoesNotDoubleRegister) {
  auto item = CreateMockItem(42);

  // Set callback BEFORE both OnNewDownload calls so we can track
  // how many times created=true is delivered.
  int created_true_count = 0;
  int created_false_count = 0;
  service_->SetChangedCallback(base::BindRepeating(
      [](int* ct, int* cf, download::DownloadItem*, bool is_created) {
        if (is_created)
          ++(*ct);
        else
          ++(*cf);
      },
      &created_true_count, &created_false_count));

  // Register the same item twice.
  service_->OnNewDownload(item.get());
  service_->OnNewDownload(item.get());

  // The first OnNewDownload fires created=true exactly once.
  // The second call must NOT fire created=true again.
  EXPECT_EQ(created_true_count, 1)
      << "Duplicate OnNewDownload must not re-fire created=true callback";

  // observed_items_ is a set, so GetAllDownloads should still return 1 entry.
  EXPECT_EQ(service_->GetAllDownloads().size(), 1u);

  // Verify only one observer callback fires per update (not two).
  int update_count = 0;
  service_->SetChangedCallback(base::BindRepeating(
      [](int* count, download::DownloadItem*, bool) { ++(*count); },
      &update_count));

  item->NotifyObserversDownloadUpdated();

  // If the observer were registered twice, we'd see update_count == 2.
  EXPECT_EQ(update_count, 1);
}

}  // namespace
}  // namespace owl
