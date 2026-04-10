// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/client/OWLTabManager.h"

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"
#import "third_party/owl/bridge/OWLBridgeSession.h"
#import "third_party/owl/bridge/OWLMojoThread.h"
#import "third_party/owl/client/OWLTab.h"

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_browser_impl.h"

namespace owl {
namespace {

void PumpUntil(bool& flag, int max_iter = 200) {
  for (int i = 0; i < max_iter && !flag; ++i) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}

class OWLTabManagerTest : public testing::Test {
 protected:
  void SetUp() override {
    [[OWLMojoThread shared] ensureStarted];

    mojo::MessagePipe pipe;
    host_ = std::make_unique<OWLBrowserImpl>("1.0.0", "/tmp/test", 0);
    host_->Bind(mojo::PendingReceiver<owl::mojom::SessionHost>(
        std::move(pipe.handle0)));

    session_ = [[OWLBridgeSession alloc]
        initWithMojoPipe:pipe.handle1.release().value()];

    __block bool ready = false;
    [session_ createBrowserContextWithPartition:nil
                                   offTheRecord:NO
                                     completion:^(OWLBridgeBrowserContext* c,
                                                  NSError*) {
      context_ = c;
      ready = true;
    }];
    PumpUntil(ready);

    tabManager_ = [[OWLTabManager alloc] initWithBrowserContext:context_
                                                   contentView:nil];
  }

  void TearDown() override {
    tabManager_ = nil;
    context_ = nil;
    session_ = nil;
    host_.reset();
    base::RunLoop().RunUntilIdle();
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBrowserImpl> host_;
  OWLBridgeSession* session_ = nil;
  OWLBridgeBrowserContext* context_ = nil;
  OWLTabManager* tabManager_ = nil;
};

TEST_F(OWLTabManagerTest, InitiallyEmpty) {
  EXPECT_EQ(tabManager_.tabCount, 0u);
  EXPECT_EQ(tabManager_.activeTab, nil);
}

TEST_F(OWLTabManagerTest, CreateTabSucceeds) {
  __block bool done = false;
  __block OWLTab* tab = nil;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError* e) {
    tab = t;
    done = true;
  }];
  PumpUntil(done);

  ASSERT_NE(tab, nil);
  EXPECT_EQ(tabManager_.tabCount, 1u);
  // First tab auto-activates.
  EXPECT_EQ(tabManager_.activeTab, tab);
}

TEST_F(OWLTabManagerTest, CreateMultipleTabs) {
  __block OWLTab* tab1 = nil;
  __block OWLTab* tab2 = nil;

  __block bool d1 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab1 = t; d1 = true;
  }];
  PumpUntil(d1);

  __block bool d2 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab2 = t; d2 = true;
  }];
  PumpUntil(d2);

  EXPECT_EQ(tabManager_.tabCount, 2u);
  // First tab remains active.
  EXPECT_EQ(tabManager_.activeTab, tab1);
}

TEST_F(OWLTabManagerTest, SwitchTab) {
  __block OWLTab* tab1 = nil;
  __block OWLTab* tab2 = nil;

  __block bool d1 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab1 = t; d1 = true;
  }];
  PumpUntil(d1);

  __block bool d2 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab2 = t; d2 = true;
  }];
  PumpUntil(d2);

  [tabManager_ activateTab:tab2.tabId];
  EXPECT_EQ(tabManager_.activeTab, tab2);

  [tabManager_ activateTab:tab1.tabId];
  EXPECT_EQ(tabManager_.activeTab, tab1);
}

TEST_F(OWLTabManagerTest, CloseActiveTabActivatesAdjacent) {
  __block OWLTab* tab1 = nil;
  __block OWLTab* tab2 = nil;

  __block bool d1 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab1 = t; d1 = true;
  }];
  PumpUntil(d1);

  __block bool d2 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab2 = t; d2 = true;
  }];
  PumpUntil(d2);

  // Close tab1 (active) → tab2 should become active.
  __block bool closed = false;
  [tabManager_ closeTab:tab1.tabId completion:^{ closed = true; }];
  PumpUntil(closed);

  EXPECT_EQ(tabManager_.tabCount, 1u);
  EXPECT_EQ(tabManager_.activeTab, tab2);
}

TEST_F(OWLTabManagerTest, CloseLastTabClearsActive) {
  __block OWLTab* tab = nil;
  __block bool d = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab = t; d = true;
  }];
  PumpUntil(d);

  __block bool closed = false;
  [tabManager_ closeTab:tab.tabId completion:^{ closed = true; }];
  PumpUntil(closed);

  EXPECT_EQ(tabManager_.tabCount, 0u);
  EXPECT_EQ(tabManager_.activeTab, nil);
}

TEST_F(OWLTabManagerTest, CloseNonActiveTabKeepsActive) {
  __block OWLTab* tab1 = nil;
  __block OWLTab* tab2 = nil;

  __block bool d1 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab1 = t; d1 = true;
  }];
  PumpUntil(d1);

  __block bool d2 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab2 = t; d2 = true;
  }];
  PumpUntil(d2);

  EXPECT_EQ(tabManager_.activeTab, tab1);

  // Close tab2 (non-active) → tab1 remains active.
  __block bool closed = false;
  [tabManager_ closeTab:tab2.tabId completion:^{ closed = true; }];
  PumpUntil(closed);

  EXPECT_EQ(tabManager_.tabCount, 1u);
  EXPECT_EQ(tabManager_.activeTab, tab1);
}

TEST_F(OWLTabManagerTest, DoubleCloseIsIdempotent) {
  __block OWLTab* tab = nil;
  __block bool d = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab = t; d = true;
  }];
  PumpUntil(d);

  __block int closeCount = 0;
  [tabManager_ closeTab:tab.tabId completion:^{ closeCount++; }];
  [tabManager_ closeTab:tab.tabId completion:^{ closeCount++; }];
  bool done = closeCount >= 2;
  PumpUntil(done);

  // Second close should be no-op (isClosing guard).
  EXPECT_EQ(tabManager_.tabCount, 0u);
}

TEST_F(OWLTabManagerTest, ActivateClosingTabIsNoOp) {
  __block OWLTab* tab1 = nil;
  __block OWLTab* tab2 = nil;

  __block bool d1 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab1 = t; d1 = true;
  }];
  PumpUntil(d1);

  __block bool d2 = false;
  [tabManager_ createTabWithURL:nil completion:^(OWLTab* t, NSError*) {
    tab2 = t; d2 = true;
  }];
  PumpUntil(d2);

  [tabManager_ activateTab:tab2.tabId];
  EXPECT_EQ(tabManager_.activeTab, tab2);

  // Start closing tab1, then try to activate it.
  [tabManager_ closeTab:tab1.tabId completion:^{}];
  [tabManager_ activateTab:tab1.tabId];
  // Should not switch to closing tab.
  EXPECT_EQ(tabManager_.activeTab, tab2);
}

}  // namespace
}  // namespace owl
