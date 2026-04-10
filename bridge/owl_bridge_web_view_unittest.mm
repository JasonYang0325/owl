// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeWebView.h"

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"
#import "third_party/owl/bridge/OWLBridgeSession.h"
#import "third_party/owl/bridge/OWLBridgeTypes.h"
#import "third_party/owl/bridge/OWLMojoThread.h"

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_browser_impl.h"

// ObjC delegate at global scope (Chromium ObjC++ restriction).
@interface TestWebViewDelegate : NSObject <OWLWebViewDelegate>
@property(nonatomic) int pageInfoCount;
@property(nonatomic, strong) OWLPageInfo* lastPageInfo;
@property(nonatomic) BOOL loadFinished;
@property(nonatomic) BOOL loadSuccess;
@end

@implementation TestWebViewDelegate
@synthesize pageInfoCount = _pageInfoCount;
@synthesize lastPageInfo = _lastPageInfo;
@synthesize loadFinished = _loadFinished;
@synthesize loadSuccess = _loadSuccess;

- (void)webView:(OWLBridgeWebView*)webView
    didUpdatePageInfo:(OWLPageInfo*)info {
  _pageInfoCount++;
  _lastPageInfo = info;
}

- (void)webView:(OWLBridgeWebView*)webView
    didFinishLoadWithSuccess:(BOOL)success {
  _loadFinished = YES;
  _loadSuccess = success;
}

- (void)webView:(OWLBridgeWebView*)webView
    didUpdateRenderSurface:(OWLRenderSurface*)surface {
  // Not tested in this phase.
}
@end

namespace owl {
namespace {

// Helper: pump both Chromium and ObjC run loops.
void PumpUntil(bool& flag, int max_iterations = 200) {
  for (int i = 0; i < max_iterations && !flag; ++i) {
    base::RunLoop().RunUntilIdle();
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}

class OWLBridgeWebViewTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    [[OWLMojoThread shared] ensureStarted];
  }

  void SetUp() override {
    // 1. Create host.
    mojo::MessagePipe pipe;
    host_ = std::make_unique<OWLBrowserImpl>("1.0.0", "/tmp/test", 0);
    host_->Bind(mojo::PendingReceiver<owl::mojom::SessionHost>(
        std::move(pipe.handle0)));

    // 2. Create bridge session.
    session_ = [[OWLBridgeSession alloc]
        initWithMojoPipe:pipe.handle1.release().value()];

    // 3. Create browser context through bridge.
    __block bool ctx_ready = false;
    [session_ createBrowserContextWithPartition:nil
                                   offTheRecord:NO
                                     completion:^(OWLBridgeBrowserContext* c,
                                                  NSError* e) {
      context_ = c;
      ctx_ready = true;
    }];
    PumpUntil(ctx_ready);

    // 4. Create web view through bridge context.
    delegate_ = [[TestWebViewDelegate alloc] init];
    __block bool wv_ready = false;
    [context_ createWebViewWithDelegate:delegate_
                             completion:^(OWLBridgeWebView* wv, NSError* e) {
      webView_ = wv;
      wv_ready = true;
    }];
    PumpUntil(wv_ready);
  }

  void TearDown() override {
    webView_ = nil;
    context_ = nil;
    session_ = nil;
    host_.reset();
    base::RunLoop().RunUntilIdle();
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBrowserImpl> host_;
  OWLBridgeSession* session_ = nil;
  OWLBridgeBrowserContext* context_ = nil;
  OWLBridgeWebView* webView_ = nil;
  TestWebViewDelegate* delegate_ = nil;
};

TEST_F(OWLBridgeWebViewTest, WebViewCreated) {
  ASSERT_NE(webView_, nil);
}

TEST_F(OWLBridgeWebViewTest, NavigateAllowedUrl) {
  __block bool completed = false;
  __block OWLNavigationResult* result = nil;
  [webView_ navigateToURL:[NSURL URLWithString:@"https://example.com"]
               completion:^(OWLNavigationResult* r) {
    result = r;
    completed = true;
  }];
  PumpUntil(completed);

  ASSERT_NE(result, nil);
  EXPECT_TRUE(result.success);
  EXPECT_EQ(result.httpStatusCode, 200);
}

TEST_F(OWLBridgeWebViewTest, NavigateBlockedUrl) {
  __block bool completed = false;
  __block OWLNavigationResult* result = nil;
  [webView_ navigateToURL:[NSURL URLWithString:@"file:///etc/passwd"]
               completion:^(OWLNavigationResult* r) {
    result = r;
    completed = true;
  }];
  PumpUntil(completed);

  ASSERT_NE(result, nil);
  EXPECT_FALSE(result.success);
}

TEST_F(OWLBridgeWebViewTest, NavigateNotifiesDelegate) {
  __block bool completed = false;
  [webView_ navigateToURL:[NSURL URLWithString:@"https://example.com"]
               completion:^(OWLNavigationResult*) {
    completed = true;
  }];
  PumpUntil(completed);

  // Pump more for observer notification.
  bool has_info = delegate_.pageInfoCount > 0;
  PumpUntil(has_info);

  EXPECT_GT(delegate_.pageInfoCount, 0);
  ASSERT_NE(delegate_.lastPageInfo, nil);
  EXPECT_TRUE([delegate_.lastPageInfo.url
      isEqualToString:@"https://example.com/"]);
}

TEST_F(OWLBridgeWebViewTest, GetPageInfo) {
  // Navigate first.
  __block bool nav_done = false;
  [webView_ navigateToURL:[NSURL URLWithString:@"https://test.com"]
               completion:^(OWLNavigationResult*) { nav_done = true; }];
  PumpUntil(nav_done);

  __block bool completed = false;
  __block OWLPageInfo* info = nil;
  [webView_ getPageInfoWithCompletion:^(OWLPageInfo* i) {
    info = i;
    completed = true;
  }];
  PumpUntil(completed);

  ASSERT_NE(info, nil);
  EXPECT_TRUE([info.url isEqualToString:@"https://test.com/"]);
}

// GetPageContent requires a live renderer pipeline; stub host returns empty.
// Covered by host-side tests: GetPageContentWithRealEvalJS, GetPageContentRealEvalJSEmptyBody.
TEST_F(OWLBridgeWebViewTest, DISABLED_GetPageContent) {
  ASSERT_NE(webView_, nil);
  __block bool completed = false;
  __block NSString* content = nil;
  [webView_ getPageContentWithCompletion:^(NSString* c) {
    content = c;
    completed = true;
  }];
  PumpUntil(completed, 500);
  ASSERT_NE(content, nil);
}

TEST_F(OWLBridgeWebViewTest, UpdateViewGeometry) {
  __block bool completed = false;
  [webView_ updateViewGeometry:CGSizeMake(1024, 768)
                   scaleFactor:2.0
                    completion:^{ completed = true; }];
  PumpUntil(completed);
  // No crash = success.
}

TEST_F(OWLBridgeWebViewTest, Close) {
  __block bool completed = false;
  [webView_ closeWithCompletion:^{ completed = true; }];
  PumpUntil(completed);
  // No crash = success.
}

}  // namespace
}  // namespace owl
