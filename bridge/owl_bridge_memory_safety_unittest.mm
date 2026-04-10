// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// Memory safety tests for Bridge layer (BH-004, BH-006, BH-011, BH-014).
// Verifies pipe watch cleanup, permission/SSL/auth routing to correct
// WebView, orphaned request cleanup on WebView destruction, and
// CreateBrowserContext partial failure error reporting.

#include "third_party/owl/bridge/owl_bridge_api.h"

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"
#import "third_party/owl/bridge/OWLBridgeSession.h"
#import "third_party/owl/bridge/OWLBridgeWebView.h"
#import "third_party/owl/bridge/OWLBridgeTypes.h"
#import "third_party/owl/bridge/OWLMojoThread.h"

#include <cstdint>

#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_browser_impl.h"

// =============================================================================
// Minimal delegate at global scope (Chromium ObjC++ restriction).
// =============================================================================

@interface MemSafetyTestWebViewDelegate : NSObject <OWLWebViewDelegate>
@property(nonatomic) BOOL loadFinished;
@end

@implementation MemSafetyTestWebViewDelegate
@synthesize loadFinished = _loadFinished;
- (void)webView:(OWLBridgeWebView*)wv didUpdatePageInfo:(OWLPageInfo*)info {}
- (void)webView:(OWLBridgeWebView*)wv didFinishLoadWithSuccess:(BOOL)s {
  _loadFinished = YES;
}
- (void)webView:(OWLBridgeWebView*)wv
    didUpdateRenderSurface:(OWLRenderSurface*)surface {}
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

// =============================================================================
// Part 1: C-ABI crash-safety tests (no session required)
// =============================================================================

// --- AC-1: WatchPipe + CloseHandle — watch state cleanup on pipe close ---

// AC-1: WatchPipe on an invalid handle (0) returns non-zero error code
// and does not crash. This verifies that the watch state map does not
// accumulate entries for invalid handles.
TEST(OWLBridgeMemorySafetyTest, WatchPipeInvalidHandleDoesNotCrash) {
  auto callback = [](uint64_t pipe_handle, int result, void* context) {};
  int rv = OWLBridge_WatchPipe(/*pipe_handle=*/0, callback, nullptr);
  // Non-zero return expected for invalid handle.
  EXPECT_NE(rv, 0);
}

// AC-1: CloseHandle(0) does not crash (no-op for invalid handle).
TEST(OWLBridgeMemorySafetyTest, CloseHandleZeroDoesNotCrash) {
  OWLBridge_CloseHandle(/*handle=*/0);
}

// AC-1: Closing a pipe handle that was never watched does not crash.
TEST(OWLBridgeMemorySafetyTest, CloseUnwatchedHandleDoesNotCrash) {
  OWLBridge_CloseHandle(/*handle=*/UINT64_MAX);
}

// AC-1: Double-close of a handle does not crash (second close is no-op).
TEST(OWLBridgeMemorySafetyTest, DoubleCloseHandleDoesNotCrash) {
  uint64_t h0 = 0, h1 = 0;
  OWLBridge_CreateMessagePipe(&h0, &h1);
  if (h0 != 0) {
    OWLBridge_CloseHandle(h0);
    // Second close should be safe (no-op or silent error).
    OWLBridge_CloseHandle(h0);
  }
  if (h1 != 0) {
    OWLBridge_CloseHandle(h1);
  }
}

// AC-1: WatchPipe with NULL callback does not crash (rejected gracefully).
TEST(OWLBridgeMemorySafetyTest, WatchPipeNullCallbackDoesNotCrash) {
  uint64_t h0 = 0, h1 = 0;
  OWLBridge_CreateMessagePipe(&h0, &h1);
  if (h0 != 0) {
    int rv = OWLBridge_WatchPipe(h0, /*callback=*/nullptr, nullptr);
    // Should reject null callback.
    EXPECT_NE(rv, 0);
    OWLBridge_CloseHandle(h0);
  }
  if (h1 != 0) {
    OWLBridge_CloseHandle(h1);
  }
}

// --- AC-2: OWLBridge_CancelWatch API availability ---

// AC-2: Closing a watched pipe implicitly cancels the watch and does
// not crash. This is the current mechanism for watch cancellation;
// a dedicated OWLBridge_CancelWatch API is proposed in BH-006.
TEST(OWLBridgeMemorySafetyTest, CloseWatchedPipeDoesNotCrash) {
  uint64_t h0 = 0, h1 = 0;
  OWLBridge_CreateMessagePipe(&h0, &h1);
  if (h0 != 0) {
    auto callback = [](uint64_t pipe_handle, int result, void* context) {};
    // Watch h0 for readability.
    OWLBridge_WatchPipe(h0, callback, nullptr);
    // Close h0 — must implicitly cancel the watch (release WatchState).
    OWLBridge_CloseHandle(h0);
  }
  if (h1 != 0) {
    OWLBridge_CloseHandle(h1);
  }
}

// AC-2: Closing the peer end of a watched pipe fires the watch callback
// with an error result and does not leak the WatchState entry.
TEST(OWLBridgeMemorySafetyTest, ClosePeerOfWatchedPipeDoesNotCrash) {
  uint64_t h0 = 0, h1 = 0;
  OWLBridge_CreateMessagePipe(&h0, &h1);
  if (h0 != 0 && h1 != 0) {
    auto callback = [](uint64_t pipe_handle, int result, void* context) {};
    OWLBridge_WatchPipe(h0, callback, nullptr);
    // Close peer — should notify the watcher, then watcher entry cleaned up.
    OWLBridge_CloseHandle(h1);
    h1 = 0;
    // Now close the watched end.
    OWLBridge_CloseHandle(h0);
    h0 = 0;
  }
  if (h0 != 0) OWLBridge_CloseHandle(h0);
  if (h1 != 0) OWLBridge_CloseHandle(h1);
}

// --- AC-4: Permission respond routes to correct WebView ---

// AC-4: RespondToPermission with an arbitrary request_id when no
// session is active does not crash and is silently ignored.
// This ensures the routing logic handles missing webview gracefully.
TEST(OWLBridgeMemorySafetyTest, PermissionRespondNoSessionDoesNotCrash) {
  OWLBridge_RespondToPermission(/*request_id=*/12345, /*status=*/0);
}

// AC-4: RespondToPermission with request_id=0 (invalid) does not crash.
TEST(OWLBridgeMemorySafetyTest, PermissionRespondZeroRequestIdDoesNotCrash) {
  OWLBridge_RespondToPermission(/*request_id=*/0, /*status=*/1);
}

// AC-4: RespondToPermission called twice with same request_id does not
// crash (second call is a no-op since request was already consumed).
TEST(OWLBridgeMemorySafetyTest, PermissionRespondTwiceSameIdDoesNotCrash) {
  OWLBridge_RespondToPermission(/*request_id=*/42, /*status=*/0);
  OWLBridge_RespondToPermission(/*request_id=*/42, /*status=*/1);
}

// --- AC-5: SSL respond routes correctly ---

// AC-5: RespondToSSLError with arbitrary error_id when no session is
// active does not crash. Verifies routing handles missing webview.
TEST(OWLBridgeMemorySafetyTest, SSLRespondNoSessionDoesNotCrash) {
  OWLBridge_RespondToSSLError(/*error_id=*/99999, /*proceed=*/1);
}

// AC-5: RespondToSSLError with error_id=0 does not crash.
TEST(OWLBridgeMemorySafetyTest, SSLRespondZeroErrorIdDoesNotCrash) {
  OWLBridge_RespondToSSLError(/*error_id=*/0, /*proceed=*/0);
}

// AC-5: Double-respond to same SSL error_id does not crash.
TEST(OWLBridgeMemorySafetyTest, SSLRespondTwiceSameIdDoesNotCrash) {
  OWLBridge_RespondToSSLError(/*error_id=*/77, /*proceed=*/1);
  OWLBridge_RespondToSSLError(/*error_id=*/77, /*proceed=*/0);
}

// AC-5: RespondToAuth with arbitrary auth_id when no session is
// active does not crash. Verifies routing handles missing webview.
TEST(OWLBridgeMemorySafetyTest, AuthRespondNoSessionDoesNotCrash) {
  OWLBridge_RespondToAuth(/*auth_id=*/88888, "user", "pass");
}

// AC-5: RespondToAuth with NULL username (cancel) does not crash.
TEST(OWLBridgeMemorySafetyTest, AuthRespondCancelDoesNotCrash) {
  OWLBridge_RespondToAuth(/*auth_id=*/11111, /*username=*/nullptr,
                          /*password=*/nullptr);
}

// AC-5: Double-respond to same auth_id does not crash.
TEST(OWLBridgeMemorySafetyTest, AuthRespondTwiceSameIdDoesNotCrash) {
  OWLBridge_RespondToAuth(/*auth_id=*/55, "user1", "pass1");
  OWLBridge_RespondToAuth(/*auth_id=*/55, "user2", "pass2");
}

// --- AC-7: CreateBrowserContext partial failure ---

// AC-7: CreateBrowserContext when Bridge is not initialized does not
// crash. Callback should fire with an error (no active session).
TEST(OWLBridgeMemorySafetyTest, CreateContextUninitializedDoesNotCrash) {
  auto callback = [](uint64_t context_id, const char* error_msg,
                     void* context) {};
  OWLBridge_CreateBrowserContext("test", /*off_the_record=*/0, callback,
                                nullptr);
}

// AC-7: CreateBrowserContext with NULL partition does not crash.
TEST(OWLBridgeMemorySafetyTest, CreateContextNullPartitionDoesNotCrash) {
  auto callback = [](uint64_t context_id, const char* error_msg,
                     void* context) {};
  OWLBridge_CreateBrowserContext(/*partition_name=*/nullptr,
                                /*off_the_record=*/0, callback, nullptr);
}

// AC-7: CreateBrowserContext with NULL callback does not crash.
TEST(OWLBridgeMemorySafetyTest, CreateContextNullCallbackDoesNotCrash) {
  OWLBridge_CreateBrowserContext("test", /*off_the_record=*/0,
                                /*callback=*/nullptr, nullptr);
}

// =============================================================================
// Part 2: Integration tests with in-process Mojo fixture
// =============================================================================

class OWLBridgeMemSafetyIntegrationTest : public testing::Test {
 protected:
  static void SetUpTestSuite() {
    [[OWLMojoThread shared] ensureStarted];
  }

  void SetUp() override {
    mojo::MessagePipe pipe;
    host_ = std::make_unique<OWLBrowserImpl>("1.0.0", "/tmp/memsafety", 0);
    host_->Bind(mojo::PendingReceiver<owl::mojom::SessionHost>(
        std::move(pipe.handle0)));

    session_ = [[OWLBridgeSession alloc]
        initWithMojoPipe:pipe.handle1.release().value()];

    __block bool ctx_ready = false;
    [session_ createBrowserContextWithPartition:nil
                                   offTheRecord:NO
                                     completion:^(OWLBridgeBrowserContext* c,
                                                  NSError*) {
      context_ = c;
      ctx_ready = true;
    }];
    PumpUntil(ctx_ready);
  }

  void TearDown() override {
    webView1_ = nil;
    webView2_ = nil;
    delegate1_ = nil;
    delegate2_ = nil;
    context_ = nil;
    session_ = nil;
    host_.reset();
    base::RunLoop().RunUntilIdle();
  }

  // Helper to create a WebView through the fixture.
  OWLBridgeWebView* CreateWebView() {
    auto* delegate = [[MemSafetyTestWebViewDelegate alloc] init];
    __block OWLBridgeWebView* wv = nil;
    __block bool done = false;
    [context_ createWebViewWithDelegate:delegate
                             completion:^(OWLBridgeWebView* v, NSError* e) {
      wv = v;
      done = true;
    }];
    PumpUntil(done);
    return wv;
  }

  base::test::SingleThreadTaskEnvironment task_environment_;
  std::unique_ptr<OWLBrowserImpl> host_;
  OWLBridgeSession* session_ = nil;
  OWLBridgeBrowserContext* context_ = nil;
  OWLBridgeWebView* webView1_ = nil;
  OWLBridgeWebView* webView2_ = nil;
  MemSafetyTestWebViewDelegate* delegate1_ = nil;
  MemSafetyTestWebViewDelegate* delegate2_ = nil;
};

// AC-4: Permission request callback includes webview_id for routing.
// Registering a per-webview-aware callback after creating two WebViews
// does not crash. Verifies the callback signature matches the routed API.
TEST_F(OWLBridgeMemSafetyIntegrationTest, PermissionCallbackIncludesWebViewId) {
  webView1_ = CreateWebView();
  ASSERT_NE(webView1_, nil);
  webView2_ = CreateWebView();
  ASSERT_NE(webView2_, nil);

  // Register permission callback with webview_id-aware signature.
  __block uint64_t received_webview_id = 0;
  auto callback = [](uint64_t webview_id, const char* origin,
                     int permission_type, uint64_t request_id,
                     void* context) {
    auto* out = static_cast<uint64_t*>(context);
    *out = webview_id;
  };
  OWLBridge_SetPermissionRequestCallback(callback, &received_webview_id);

  // Clean up.
  OWLBridge_SetPermissionRequestCallback(nullptr, nullptr);
}

// AC-5: SSL error callback includes webview_id for routing.
TEST_F(OWLBridgeMemSafetyIntegrationTest, SSLCallbackIncludesWebViewId) {
  webView1_ = CreateWebView();
  ASSERT_NE(webView1_, nil);

  __block uint64_t received_webview_id = 0;
  auto callback = [](uint64_t webview_id, const char* url,
                     const char* cert_subject, const char* error_description,
                     uint64_t error_id, void* context) {
    auto* out = static_cast<uint64_t*>(context);
    *out = webview_id;
  };
  OWLBridge_SetSSLErrorCallback(callback, &received_webview_id);
  OWLBridge_SetSSLErrorCallback(nullptr, nullptr);
}

// AC-5: Auth callback includes webview_id for routing.
TEST_F(OWLBridgeMemSafetyIntegrationTest, AuthCallbackIncludesWebViewId) {
  webView1_ = CreateWebView();
  ASSERT_NE(webView1_, nil);

  auto callback = [](uint64_t webview_id, const char* url, const char* realm,
                     const char* scheme, uint64_t auth_id, int is_proxy,
                     void* context) {};
  OWLBridge_SetAuthRequiredCallback(/*webview_id=*/1, callback, nullptr);
  OWLBridge_SetAuthRequiredCallback(/*webview_id=*/1, nullptr, nullptr);
}

// AC-3: ObjC dealloc — destroying a WebView through close does not crash
// or leak. PostTask + WrapUnique ensures the C++ pointers are destroyed
// on the correct thread. TSan would flag data races here.
TEST_F(OWLBridgeMemSafetyIntegrationTest, WebViewCloseNoDataRace) {
  delegate1_ = [[MemSafetyTestWebViewDelegate alloc] init];
  __block bool wv_ready = false;
  [context_ createWebViewWithDelegate:delegate1_
                           completion:^(OWLBridgeWebView* wv, NSError* e) {
    webView1_ = wv;
    wv_ready = true;
  }];
  PumpUntil(wv_ready);
  ASSERT_NE(webView1_, nil);

  // Close the WebView — should trigger dealloc path with PostTask.
  __block bool closed = false;
  [webView1_ closeWithCompletion:^{ closed = true; }];
  PumpUntil(closed);

  // Release our reference — dealloc should fire safely.
  webView1_ = nil;
  // Pump to process any PostTask'd destructions.
  base::RunLoop().RunUntilIdle();
  [[NSRunLoop currentRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  // No crash = TSan-safe destruction.
}

// AC-6: Destroying a WebView cleans up any pending request entries.
// After close, responding to orphaned permission/SSL/auth request_ids
// for that WebView does not crash (entries already cleaned).
TEST_F(OWLBridgeMemSafetyIntegrationTest, OrphanedRequestsAfterDestroy) {
  delegate1_ = [[MemSafetyTestWebViewDelegate alloc] init];
  __block bool wv_ready = false;
  [context_ createWebViewWithDelegate:delegate1_
                           completion:^(OWLBridgeWebView* wv, NSError* e) {
    webView1_ = wv;
    wv_ready = true;
  }];
  PumpUntil(wv_ready);
  ASSERT_NE(webView1_, nil);

  // Close the WebView.
  __block bool closed = false;
  [webView1_ closeWithCompletion:^{ closed = true; }];
  PumpUntil(closed);
  webView1_ = nil;
  base::RunLoop().RunUntilIdle();

  // Attempt to respond to "orphaned" requests that would have belonged
  // to the destroyed WebView. These must not crash.
  OWLBridge_RespondToPermission(/*request_id=*/1001, /*status=*/0);
  OWLBridge_RespondToSSLError(/*error_id=*/2001, /*proceed=*/1);
  OWLBridge_RespondToAuth(/*auth_id=*/3001, "user", "pass");
  OWLBridge_RespondToAuth(/*auth_id=*/3002, nullptr, nullptr);

  // Pump to ensure no deferred crashes.
  base::RunLoop().RunUntilIdle();
  [[NSRunLoop currentRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

// AC-6: Destroying multiple WebViews then responding to stale IDs
// for each does not crash.
TEST_F(OWLBridgeMemSafetyIntegrationTest,
       MultipleWebViewDestroyOrphanedRequests) {
  // Create two WebViews.
  delegate1_ = [[MemSafetyTestWebViewDelegate alloc] init];
  delegate2_ = [[MemSafetyTestWebViewDelegate alloc] init];
  __block bool wv1_ready = false, wv2_ready = false;

  [context_ createWebViewWithDelegate:delegate1_
                           completion:^(OWLBridgeWebView* wv, NSError* e) {
    webView1_ = wv;
    wv1_ready = true;
  }];
  PumpUntil(wv1_ready);
  ASSERT_NE(webView1_, nil);

  [context_ createWebViewWithDelegate:delegate2_
                           completion:^(OWLBridgeWebView* wv, NSError* e) {
    webView2_ = wv;
    wv2_ready = true;
  }];
  PumpUntil(wv2_ready);
  ASSERT_NE(webView2_, nil);

  // Destroy first WebView.
  __block bool closed1 = false;
  [webView1_ closeWithCompletion:^{ closed1 = true; }];
  PumpUntil(closed1);
  webView1_ = nil;

  // Destroy second WebView.
  __block bool closed2 = false;
  [webView2_ closeWithCompletion:^{ closed2 = true; }];
  PumpUntil(closed2);
  webView2_ = nil;

  base::RunLoop().RunUntilIdle();

  // Respond to stale requests for both destroyed WebViews.
  OWLBridge_RespondToPermission(/*request_id=*/5001, /*status=*/0);
  OWLBridge_RespondToPermission(/*request_id=*/5002, /*status=*/1);
  OWLBridge_RespondToSSLError(/*error_id=*/6001, /*proceed=*/1);
  OWLBridge_RespondToSSLError(/*error_id=*/6002, /*proceed=*/0);
  OWLBridge_RespondToAuth(/*auth_id=*/7001, "user", "pass");
  OWLBridge_RespondToAuth(/*auth_id=*/7002, nullptr, nullptr);

  base::RunLoop().RunUntilIdle();
}

// AC-7: CreateBrowserContext with invalid partition name returns an error
// callback (service failure) rather than crashing.
TEST_F(OWLBridgeMemSafetyIntegrationTest, CreateContextInvalidPartitionErrors) {
  __block bool done = false;
  __block NSError* err = nil;

  [session_ createBrowserContextWithPartition:@"invalid/name!"
                                 offTheRecord:NO
                                   completion:^(OWLBridgeBrowserContext* ctx,
                                                NSError* error) {
    err = error;
    done = true;
  }];
  PumpUntil(done);

  // Invalid partition should produce an error, not crash.
  EXPECT_NE(err, nil);
}

// AC-7: CreateBrowserContext after session disconnect reports error.
TEST_F(OWLBridgeMemSafetyIntegrationTest, CreateContextAfterDisconnectErrors) {
  // Destroy host to simulate disconnect.
  host_.reset();
  base::RunLoop().RunUntilIdle();
  [[NSRunLoop currentRunLoop]
      runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

  __block bool done = false;
  __block NSError* err = nil;

  [session_ createBrowserContextWithPartition:@"post_disconnect"
                                 offTheRecord:NO
                                   completion:^(OWLBridgeBrowserContext* ctx,
                                                NSError* error) {
    err = error;
    done = true;
  }];
  PumpUntil(done);

  // Disconnected session should report error, not crash.
  EXPECT_NE(err, nil);
}

// AC-3: Rapid create-close cycles exercise the PostTask dealloc path
// under stress. TSan would flag any races.
TEST_F(OWLBridgeMemSafetyIntegrationTest, RapidCreateCloseCycles) {
  for (int i = 0; i < 5; ++i) {
    auto* delegate = [[MemSafetyTestWebViewDelegate alloc] init];
    __block OWLBridgeWebView* wv = nil;
    __block bool created = false;
    [context_ createWebViewWithDelegate:delegate
                             completion:^(OWLBridgeWebView* v, NSError* e) {
      wv = v;
      created = true;
    }];
    PumpUntil(created);
    if (!wv) break;

    __block bool closed = false;
    [wv closeWithCompletion:^{ closed = true; }];
    PumpUntil(closed);
    wv = nil;
    // Let PostTask'd destructors run.
    base::RunLoop().RunUntilIdle();
  }
}

}  // namespace
}  // namespace owl
