// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_browser_impl.h"

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/mojom/browser_context.mojom.h"
#include "third_party/owl/mojom/owl_types.mojom.h"
#include "third_party/owl/mojom/session.mojom.h"

namespace owl {
namespace {

class OWLBrowserImplTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    static bool mojo_initialized = false;
    if (!mojo_initialized) {
      mojo::core::Init();
      mojo_initialized = true;
    }
  }

  void SetUp() override {
    browser_ = std::make_unique<OWLBrowserImpl>(
        "1.0.0", "/tmp/owl-test-data", 0);
    browser_->Bind(session_.BindNewPipeAndPassReceiver());
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBrowserImpl> browser_;
  mojo::Remote<owl::mojom::SessionHost> session_;
};

TEST_F(OWLBrowserImplTest, GetHostInfoReturnsConfig) {
  base::RunLoop run_loop;
  session_->GetHostInfo(base::BindOnce(
      [](base::RunLoop* loop, const std::string& version,
         const std::string& user_data_dir, uint16_t devtools_port) {
        EXPECT_EQ(version, "1.0.0");
        EXPECT_EQ(user_data_dir, "/tmp/owl-test-data");
        EXPECT_EQ(devtools_port, 0u);
        loop->Quit();
      },
      &run_loop));
  run_loop.Run();
}

TEST_F(OWLBrowserImplTest, CreateBrowserContextSucceeds) {
  auto config = owl::mojom::ProfileConfig::New();
  config->partition_name = "test_partition";
  config->off_the_record = false;

  mojo::Remote<owl::mojom::BrowserContextHost> context_remote;
  base::RunLoop run_loop;
  session_->CreateBrowserContext(
      std::move(config),
      base::BindOnce(
          [](mojo::Remote<owl::mojom::BrowserContextHost>* out,
             base::RunLoop* loop,
             mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
            EXPECT_TRUE(context.is_valid());
            out->Bind(std::move(context));
            loop->Quit();
          },
          &context_remote, &run_loop));
  run_loop.Run();

  EXPECT_EQ(browser_->browser_context_count(), 1u);
}

TEST_F(OWLBrowserImplTest, CreateMultipleBrowserContexts) {
  // Keep remotes alive so disconnect handlers don't fire.
  std::vector<mojo::Remote<owl::mojom::BrowserContextHost>> remotes;

  for (int i = 0; i < 3; ++i) {
    auto config = owl::mojom::ProfileConfig::New();
    config->off_the_record = true;

    base::RunLoop run_loop;
    session_->CreateBrowserContext(
        std::move(config),
        base::BindOnce(
            [](std::vector<mojo::Remote<owl::mojom::BrowserContextHost>>* vec,
               base::RunLoop* loop,
               mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
              vec->emplace_back(std::move(context));
              loop->Quit();
            },
            &remotes, &run_loop));
    run_loop.Run();
  }

  EXPECT_EQ(browser_->browser_context_count(), 3u);
}

TEST_F(OWLBrowserImplTest, RejectsInvalidPartitionName) {
  auto config = owl::mojom::ProfileConfig::New();
  config->partition_name = "invalid/name with spaces!";
  config->off_the_record = false;

  base::RunLoop run_loop;
  session_->CreateBrowserContext(
      std::move(config),
      base::BindOnce(
          [](base::RunLoop* loop,
             mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
            // Nullable mojom: invalid partition returns null remote.
            EXPECT_FALSE(context.is_valid());
            loop->Quit();
          },
          &run_loop));
  run_loop.Run();

  EXPECT_EQ(browser_->browser_context_count(), 0u);
}

TEST_F(OWLBrowserImplTest, AcceptsValidPartitionNames) {
  const char* valid_names[] = {"default", "test-1", "user_profile", "A_B-C"};
  for (const char* name : valid_names) {
    auto config = owl::mojom::ProfileConfig::New();
    config->partition_name = name;
    config->off_the_record = false;

    base::RunLoop run_loop;
    session_->CreateBrowserContext(
        std::move(config),
        base::BindOnce(
            [](base::RunLoop* loop,
               mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
              EXPECT_TRUE(context.is_valid());
              loop->Quit();
            },
            &run_loop));
    run_loop.Run();
  }
}

TEST_F(OWLBrowserImplTest, ShutdownSetsFlag) {
  EXPECT_FALSE(browser_->is_shutting_down());

  base::RunLoop run_loop;
  session_->Shutdown(base::BindOnce(
      [](base::RunLoop* loop) { loop->Quit(); }, &run_loop));
  run_loop.Run();

  EXPECT_TRUE(browser_->is_shutting_down());
}

TEST_F(OWLBrowserImplTest, ShutdownRejectsNewContexts) {
  // First shutdown.
  {
    base::RunLoop run_loop;
    session_->Shutdown(base::BindOnce(
        [](base::RunLoop* loop) { loop->Quit(); }, &run_loop));
    run_loop.Run();
  }

  // Now try to create a context — should return null (nullable mojom).
  auto config = owl::mojom::ProfileConfig::New();
  base::RunLoop run_loop;
  session_->CreateBrowserContext(
      std::move(config),
      base::BindOnce(
          [](base::RunLoop* loop,
             mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
            EXPECT_FALSE(context.is_valid());
            loop->Quit();
          },
          &run_loop));
  run_loop.Run();

  EXPECT_EQ(browser_->browser_context_count(), 0u);
}

// [P1] Missing: Context disconnect triggers cleanup.
TEST_F(OWLBrowserImplTest, ContextDisconnectRemovesFromParent) {
  {
    mojo::Remote<owl::mojom::BrowserContextHost> ctx;
    auto config = owl::mojom::ProfileConfig::New();
    base::RunLoop run_loop;
    session_->CreateBrowserContext(
        std::move(config),
        base::BindOnce(
            [](mojo::Remote<owl::mojom::BrowserContextHost>* out,
               base::RunLoop* loop,
               mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
              out->Bind(std::move(context));
              loop->Quit();
            },
            &ctx, &run_loop));
    run_loop.Run();
    EXPECT_EQ(browser_->browser_context_count(), 1u);
    // ctx goes out of scope here → disconnect handler fires.
  }
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(browser_->browser_context_count(), 0u);
}

// [P0] Missing-2: Shutdown notifies observer.
class FakeSessionObserver : public owl::mojom::SessionObserver {
 public:
  void OnShutdown() override { shutdown_received_ = true; }
  bool shutdown_received_ = false;
};

TEST_F(OWLBrowserImplTest, ShutdownNotifiesObserver) {
  auto observer = std::make_unique<FakeSessionObserver>();
  mojo::Receiver<owl::mojom::SessionObserver> receiver(observer.get());
  session_->SetObserver(receiver.BindNewPipeAndPassRemote());
  base::RunLoop().RunUntilIdle();

  base::RunLoop run_loop;
  session_->Shutdown(base::BindOnce(
      [](base::RunLoop* loop) { loop->Quit(); }, &run_loop));
  run_loop.Run();
  base::RunLoop().RunUntilIdle();

  EXPECT_TRUE(observer->shutdown_received_);
}

// [P1] Missing-3: Shutdown clears existing contexts.
TEST_F(OWLBrowserImplTest, ShutdownClearsExistingContexts) {
  mojo::Remote<owl::mojom::BrowserContextHost> ctx;
  {
    auto config = owl::mojom::ProfileConfig::New();
    base::RunLoop run_loop;
    session_->CreateBrowserContext(
        std::move(config),
        base::BindOnce(
            [](mojo::Remote<owl::mojom::BrowserContextHost>* out,
               base::RunLoop* loop,
               mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
              out->Bind(std::move(context));
              loop->Quit();
            },
            &ctx, &run_loop));
    run_loop.Run();
  }
  EXPECT_EQ(browser_->browser_context_count(), 1u);

  base::RunLoop run_loop;
  session_->Shutdown(base::BindOnce(
      [](base::RunLoop* loop) { loop->Quit(); }, &run_loop));
  run_loop.Run();

  EXPECT_EQ(browser_->browser_context_count(), 0u);
}

// [P1] Missing-1: SetObserver replaces previous.
TEST_F(OWLBrowserImplTest, SetObserverReplacesPrevious) {
  auto obs1 = std::make_unique<FakeSessionObserver>();
  mojo::Receiver<owl::mojom::SessionObserver> rec1(obs1.get());
  session_->SetObserver(rec1.BindNewPipeAndPassRemote());
  base::RunLoop().RunUntilIdle();

  auto obs2 = std::make_unique<FakeSessionObserver>();
  mojo::Receiver<owl::mojom::SessionObserver> rec2(obs2.get());
  session_->SetObserver(rec2.BindNewPipeAndPassRemote());
  base::RunLoop().RunUntilIdle();

  base::RunLoop run_loop;
  session_->Shutdown(base::BindOnce(
      [](base::RunLoop* loop) { loop->Quit(); }, &run_loop));
  run_loop.Run();
  base::RunLoop().RunUntilIdle();

  EXPECT_FALSE(obs1->shutdown_received_);
  EXPECT_TRUE(obs2->shutdown_received_);
}

// [P2] Missing-5: Partition name too long.
TEST_F(OWLBrowserImplTest, RejectsTooLongPartitionName) {
  auto config = owl::mojom::ProfileConfig::New();
  config->partition_name = std::string(65, 'a');
  config->off_the_record = false;

  base::RunLoop run_loop;
  session_->CreateBrowserContext(
      std::move(config),
      base::BindOnce(
          [](base::RunLoop* loop,
             mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
            EXPECT_FALSE(context.is_valid());
            loop->Quit();
          },
          &run_loop));
  run_loop.Run();
}

// [P1] Gemini: Session disconnect triggers shutdown.
TEST_F(OWLBrowserImplTest, SessionDisconnectTriggersShutdown) {
  // Create a context first.
  mojo::Remote<owl::mojom::BrowserContextHost> ctx;
  {
    auto config = owl::mojom::ProfileConfig::New();
    base::RunLoop run_loop;
    session_->CreateBrowserContext(
        std::move(config),
        base::BindOnce(
            [](mojo::Remote<owl::mojom::BrowserContextHost>* out,
               base::RunLoop* loop,
               mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
              out->Bind(std::move(context));
              loop->Quit();
            },
            &ctx, &run_loop));
    run_loop.Run();
  }
  EXPECT_EQ(browser_->browser_context_count(), 1u);
  EXPECT_FALSE(browser_->is_shutting_down());

  // Drop the session remote → disconnect handler fires.
  session_.reset();
  base::RunLoop().RunUntilIdle();

  EXPECT_TRUE(browser_->is_shutting_down());
  EXPECT_EQ(browser_->browser_context_count(), 0u);
}

}  // namespace
}  // namespace owl
