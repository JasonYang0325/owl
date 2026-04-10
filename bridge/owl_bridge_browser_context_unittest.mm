// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"

#import "third_party/owl/bridge/OWLBridgeSession.h"
#import "third_party/owl/bridge/OWLBridgeWebView.h"
#import "third_party/owl/bridge/OWLMojoThread.h"

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_browser_impl.h"

// Minimal delegate at global scope.
@interface MinimalWebViewDelegate : NSObject <OWLWebViewDelegate>
@end

@implementation MinimalWebViewDelegate
- (void)webView:(OWLBridgeWebView*)wv didUpdatePageInfo:(OWLPageInfo*)info {}
- (void)webView:(OWLBridgeWebView*)wv didFinishLoadWithSuccess:(BOOL)s {}
- (void)webView:(OWLBridgeWebView*)wv
    didUpdateRenderSurface:(OWLRenderSurface*)surface {}
@end

namespace owl {
namespace {

void PumpUntil(bool& flag, int max_iter = 200) {
  for (int i = 0; i < max_iter && !flag; ++i) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}

class OWLBridgeBrowserContextTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    [[OWLMojoThread shared] ensureStarted];
  }

  void SetUp() override {
    mojo::MessagePipe pipe;
    host_ = std::make_unique<OWLBrowserImpl>("1.0.0", "/tmp/test", 0);
    host_->Bind(mojo::PendingReceiver<owl::mojom::SessionHost>(
        std::move(pipe.handle0)));

    session_ = [[OWLBridgeSession alloc]
        initWithMojoPipe:pipe.handle1.release().value()];

    // Create context.
    __block bool ready = false;
    [session_ createBrowserContextWithPartition:nil
                                   offTheRecord:NO
                                     completion:^(OWLBridgeBrowserContext* c,
                                                  NSError*) {
      context_ = c;
      ready = true;
    }];
    PumpUntil(ready);
  }

  void TearDown() override {
    context_ = nil;
    session_ = nil;
    host_.reset();
    base::RunLoop().RunUntilIdle();
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBrowserImpl> host_;
  OWLBridgeSession* session_ = nil;
  OWLBridgeBrowserContext* context_ = nil;
};

TEST_F(OWLBridgeBrowserContextTest, ContextCreated) {
  ASSERT_NE(context_, nil);
}

TEST_F(OWLBridgeBrowserContextTest, CreateWebViewSucceeds) {
  MinimalWebViewDelegate* delegate = [[MinimalWebViewDelegate alloc] init];
  __block bool done = false;
  __block OWLBridgeWebView* wv = nil;
  [context_ createWebViewWithDelegate:delegate
                           completion:^(OWLBridgeWebView* v, NSError* e) {
    wv = v;
    done = true;
  }];
  PumpUntil(done);
  EXPECT_NE(wv, nil);
}

TEST_F(OWLBridgeBrowserContextTest, DestroySucceeds) {
  __block bool done = false;
  [context_ destroyWithCompletion:^{ done = true; }];
  PumpUntil(done);
  EXPECT_TRUE(done);
}

TEST_F(OWLBridgeBrowserContextTest, CreateWebViewAfterDestroyFails) {
  // Destroy first.
  __block bool destroyed = false;
  [context_ destroyWithCompletion:^{ destroyed = true; }];
  PumpUntil(destroyed);

  // Now try to create a WebView — should fail (disconnected).
  MinimalWebViewDelegate* delegate = [[MinimalWebViewDelegate alloc] init];
  __block bool done = false;
  __block NSError* err = nil;
  [context_ createWebViewWithDelegate:delegate
                           completion:^(OWLBridgeWebView* v, NSError* e) {
    err = e;
    done = true;
  }];
  PumpUntil(done);
  EXPECT_NE(err, nil);
}

}  // namespace
}  // namespace owl
