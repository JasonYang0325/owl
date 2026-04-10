// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeSession.h"
#import "third_party/owl/bridge/OWLMojoThread.h"

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_browser_impl.h"
#include "third_party/owl/mojom/session.mojom.h"

namespace owl {
namespace {

// Test fixture that creates an in-process Mojo pipe pair:
// one end bound to OWLBrowserImpl (host), other end to OWLBridgeSession.
class OWLBridgeSessionTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    [[OWLMojoThread shared] ensureStarted];
  }

  void SetUp() override {
    // Create a message pipe pair.
    mojo::MessagePipe pipe;

    // Host side: bind OWLBrowserImpl to one end.
    host_ = std::make_unique<OWLBrowserImpl>("1.0.0", "/tmp/test", 0);
    host_->Bind(mojo::PendingReceiver<owl::mojom::SessionHost>(
        std::move(pipe.handle0)));

    // Bridge side: create session with the other end.
    session_ = [[OWLBridgeSession alloc]
        initWithMojoPipe:pipe.handle1.release().value()];
    ASSERT_NE(session_, nil);
  }

  void TearDown() override {
    session_ = nil;
    host_.reset();
    // Flush pending tasks.
    base::RunLoop().RunUntilIdle();
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBrowserImpl> host_;
  OWLBridgeSession* session_;
};

TEST_F(OWLBridgeSessionTest, GetHostInfoReturnsConfig) {
  __block bool completed = false;
  [session_ getHostInfoWithCompletion:^(NSString* version,
                                        NSString* userDataDir,
                                        uint16_t devtoolsPort,
                                        NSError* error) {
    EXPECT_EQ(error, nil);
    EXPECT_TRUE([version isEqualToString:@"1.0.0"]);
    EXPECT_TRUE([userDataDir isEqualToString:@"/tmp/test"]);
    EXPECT_EQ(devtoolsPort, 0u);
    completed = true;
  }];

  // Pump message loops until completion.
  while (!completed) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}

TEST_F(OWLBridgeSessionTest, CreateBrowserContextSucceeds) {
  __block bool completed = false;
  __block OWLBridgeBrowserContext* ctx = nil;

  [session_ createBrowserContextWithPartition:@"test"
                                 offTheRecord:NO
                                   completion:^(OWLBridgeBrowserContext* context,
                                                NSError* error) {
    EXPECT_EQ(error, nil);
    EXPECT_NE(context, nil);
    ctx = context;
    completed = true;
  }];

  while (!completed) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:0.01]];
  }

  EXPECT_EQ(host_->browser_context_count(), 1u);
}

TEST_F(OWLBridgeSessionTest, ShutdownSetsFlag) {
  __block bool completed = false;
  [session_ shutdownWithCompletion:^{
    completed = true;
  }];

  while (!completed) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:0.01]];
  }

  EXPECT_TRUE(host_->is_shutting_down());
}

TEST_F(OWLBridgeSessionTest, RejectsInvalidPartitionName) {
  __block bool completed = false;
  [session_ createBrowserContextWithPartition:@"invalid/name!"
                                 offTheRecord:NO
                                   completion:^(OWLBridgeBrowserContext* context,
                                                NSError* error) {
    // Nullable mojom: invalid partition returns nil context.
    EXPECT_EQ(context, nil);
    EXPECT_NE(error, nil);
    completed = true;
  }];

  while (!completed) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}

}  // namespace
}  // namespace owl

// ObjC declarations must be at global scope.
@interface TestSessionDelegate : NSObject <OWLSessionDelegate>
@property(nonatomic) BOOL shutdownReceived;
@property(nonatomic) BOOL disconnectReceived;
@end

@implementation TestSessionDelegate
@synthesize shutdownReceived = _shutdownReceived;
@synthesize disconnectReceived = _disconnectReceived;
- (void)sessionDidShutdown { self.shutdownReceived = YES; }
- (void)sessionDidDisconnect { self.disconnectReceived = YES; }
@end

namespace owl {
namespace {

TEST_F(OWLBridgeSessionTest, DisconnectNotifiesDelegate) {
  TestSessionDelegate* delegate = [[TestSessionDelegate alloc] init];
  session_.delegate = delegate;

  // Destroy host side → bridge should detect disconnect.
  host_.reset();

  // Pump until delegate fires.
  for (int i = 0; i < 100 && !delegate.disconnectReceived; ++i) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:0.01]];
  }

  EXPECT_TRUE(delegate.disconnectReceived);
}

}  // namespace
}  // namespace owl
