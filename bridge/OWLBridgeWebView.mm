// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeWebView.h"

#include "base/functional/bind.h"
#include "base/memory/ptr_util.h"
#include "base/task/sequenced_task_runner.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "third_party/owl/mojom/owl_input_types.mojom.h"
#include "third_party/owl/mojom/owl_types.mojom.h"
#include "third_party/owl/mojom/web_view.mojom.h"
#include "url/gurl.h"

// C++ observer bridge: receives Mojo callbacks on current thread,
// dispatches to ObjC delegate on main thread.
class WebViewObserverBridge : public owl::mojom::WebViewObserver {
 public:
  void SetView(OWLBridgeWebView* __weak view) { view_ = view; }

  void OnPageInfoChanged(owl::mojom::PageInfoPtr info) override {
    OWLPageInfo* objc_info =
        [OWLPageInfo infoWithTitle:@(info->title.c_str())
                               url:@(info->url.c_str())
                         isLoading:info->is_loading
                         canGoBack:info->can_go_back
                        canGoForward:info->can_go_forward];
    OWLBridgeWebView* strong = view_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([strong.delegate respondsToSelector:
              @selector(webView:didUpdatePageInfo:)]) {
        [strong.delegate webView:strong didUpdatePageInfo:objc_info];
      }
    });
  }

  void OnLoadFinished(bool success) override {
    OWLBridgeWebView* strong = view_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([strong.delegate respondsToSelector:
              @selector(webView:didFinishLoadWithSuccess:)]) {
        [strong.delegate webView:strong didFinishLoadWithSuccess:success];
      }
    });
  }

  void OnRenderSurfaceChanged(uint32_t ca_context_id,
                              mojo::PlatformHandle io_surface,
                              const gfx::Size& pixel_size,
                              float scale_factor) override {
    uint32_t mach_port = io_surface.is_valid_mach_send()
        ? io_surface.ReleaseMachSendRight()
        : 0;
    OWLRenderSurface* surface =
        [OWLRenderSurface surfaceWithContextId:ca_context_id
                              ioSurfaceMachPort:mach_port
                                     pixelSize:CGSizeMake(pixel_size.width(),
                                                          pixel_size.height())
                                   scaleFactor:scale_factor];
    OWLBridgeWebView* strong = view_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([strong.delegate respondsToSelector:
              @selector(webView:didUpdateRenderSurface:)]) {
        [strong.delegate webView:strong didUpdateRenderSurface:surface];
      }
    });
  }

  void OnUnhandledKeyEvent(owl::mojom::KeyEventPtr event) override {
    OWLKeyEvent* objc_event = [OWLKeyEvent
        eventWithType:static_cast<int32_t>(event->type)
        nativeKeyCode:event->native_key_code
            modifiers:event->modifiers
           characters:event->characters.has_value()
                          ? @(event->characters.value().c_str())
                          : nil];
    OWLBridgeWebView* strong = view_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([strong.delegate respondsToSelector:
              @selector(webView:didReceiveUnhandledKeyEvent:)]) {
        [strong.delegate webView:strong
            didReceiveUnhandledKeyEvent:objc_event];
      }
    });
  }

  void OnCursorChanged(owl::mojom::CursorType cursor_type) override {
    // Cursor changes handled via C-ABI callback path (owl_bridge_api.cc).
  }

  void OnCaretRectChanged(const gfx::Rect& caret_rect) override {
    // Caret rect handled via C-ABI callback path (owl_bridge_api.cc).
  }

  void OnFindReply(int32_t request_id, int32_t number_of_matches,
                   int32_t active_match_ordinal, bool final_update) override {
    // Find results handled via C-ABI callback path (owl_bridge_api.cc).
  }

  void OnZoomLevelChanged(double new_level) override {
    // Zoom changes handled via C-ABI callback path (owl_bridge_api.cc).
  }

  void OnPermissionRequest(const std::string& origin,
                           owl::mojom::PermissionType permission_type,
                           uint64_t request_id) override {
    // Permission requests handled via C-ABI callback path (owl_bridge_api.cc).
  }

  // Phase 4: SSL error and security state handled via C-ABI callback path.
  void OnSSLError(const std::string& url,
                  const std::string& cert_subject,
                  const std::string& error_description,
                  uint64_t error_id) override {
    // SSL errors handled via C-ABI callback path (owl_bridge_api.cc).
  }

  void OnSecurityStateChanged(int32_t level,
                               const std::string& cert_subject,
                               const std::string& error_description) override {
    // Security state changes handled via C-ABI callback path (owl_bridge_api.cc).
  }

  // Phase 3: Context menu handled via C-ABI callback path (owl_bridge_api.cc).
  void OnContextMenu(owl::mojom::ContextMenuParamsPtr params) override {
    // Context menu handled via C-ABI callback path (owl_bridge_api.cc).
  }

  // Phase 3: Copy-image result handled via C-ABI callback path (owl_bridge_api.cc).
  void OnCopyImageResult(bool success,
                         const std::optional<std::string>& fallback_url) override {
    // Copy-image result handled via C-ABI callback path (owl_bridge_api.cc).
  }

  // Phase 3: HTTP Auth challenge handled via C-ABI callback path (owl_bridge_api.cc).
  void OnAuthRequired(const std::string& url,
                      const std::string& realm,
                      const std::string& scheme,
                      uint64_t auth_id,
                      bool is_proxy) override {
    // Auth challenges handled via C-ABI callback path (owl_bridge_api.cc).
  }

  // Console message — Phase 1 stub (C-ABI wiring deferred to Phase 2).
  void OnConsoleMessage(owl::mojom::ConsoleMessagePtr message) override {
    // Phase 1 stub: C-ABI callback wiring deferred to Phase 2.
  }

  // Navigation lifecycle events — Phase 1 stubs (C-ABI wiring in Phase 2).
  void OnNavigationStarted(owl::mojom::NavigationEventPtr event) override {
    // Phase 1 stub: C-ABI callback wiring deferred to Phase 2.
  }
  void OnNavigationCommitted(owl::mojom::NavigationEventPtr event) override {
    // Phase 1 stub: C-ABI callback wiring deferred to Phase 2.
  }
  void OnNavigationFailed(int64_t navigation_id,
                          const std::string& url,
                          int32_t error_code,
                          const std::string& error_description) override {
    // Phase 1 stub: C-ABI callback wiring deferred to Phase 2.
  }

  // Phase 3 Multi-tab: New tab requested — handled via C-ABI callback path.
  void OnNewTabRequested(const std::string& url, bool foreground) override {
    // New tab requests handled via C-ABI callback path (owl_bridge_api.cc).
  }

  void OnWebViewCloseRequested() override {
    // Close requests handled via C-ABI callback path (owl_bridge_api.cc).
  }

 private:
  OWLBridgeWebView* __weak view_ = nil;
};

namespace {

struct WebViewMojoState {
  mojo::Remote<owl::mojom::WebViewHost> remote;
  std::unique_ptr<WebViewObserverBridge> observer_bridge;
  std::optional<mojo::Receiver<owl::mojom::WebViewObserver>> observer_receiver;
  // Task runner the remote was bound on (captured at bind time).
  scoped_refptr<base::SequencedTaskRunner> bound_runner;

  void BindObserver() {
    observer_receiver.emplace(observer_bridge.get());
  }
};

}  // namespace

@implementation OWLBridgeWebView {
  WebViewMojoState* _state;
  __weak id<OWLWebViewDelegate> _delegate;
}

@synthesize delegate = _delegate;

- (nullable instancetype)initWithMojoPipe:(uint64_t)pipeHandle
                         observerPipe:(uint64_t)observerPipeHandle
                                 delegate:(id<OWLWebViewDelegate>)delegate {
  self = [super init];
  if (!self) return nil;

  _delegate = delegate;
  _state = new WebViewMojoState();

  // Bind WebViewHost remote.
  mojo::ScopedMessagePipeHandle pipe{mojo::MessagePipeHandle{pipeHandle}};
  _state->remote.Bind(
      mojo::PendingRemote<owl::mojom::WebViewHost>{std::move(pipe), 0});

  _state->bound_runner = base::SequencedTaskRunner::GetCurrentDefault();

  // Bind observer receiver (receives callbacks from Host).
  _state->observer_bridge = std::make_unique<WebViewObserverBridge>();
  _state->observer_bridge->SetView(self);
  mojo::ScopedMessagePipeHandle obs_pipe{
      mojo::MessagePipeHandle{observerPipeHandle}};
  _state->observer_receiver.emplace(
      _state->observer_bridge.get(),
      mojo::PendingReceiver<owl::mojom::WebViewObserver>{
          std::move(obs_pipe)});

  return self;
}

- (void)dealloc {
  WebViewMojoState* state = _state;
  _state = nullptr;
  if (!state) return;

  auto runner = state->bound_runner;
  if (runner && !runner->RunsTasksInCurrentSequence()) {
    // WrapUnique ensures deletion even if PostTask is dropped (IO thread stopped).
    runner->PostTask(FROM_HERE,
                     base::BindOnce([](std::unique_ptr<WebViewMojoState>) {},
                                    base::WrapUnique(state)));
  } else {
    delete state;  // Already on correct thread, or no runner available.
  }
}

- (void)navigateToURL:(NSURL*)url
           completion:(void (^)(OWLNavigationResult*))completion {
  if (!_state || !_state->remote.is_connected()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion([OWLNavigationResult resultWithSuccess:NO
                                        httpStatusCode:0
                                      errorDescription:@"Not connected"]);
    });
    return;
  }

  _state->remote->Navigate(
      GURL([[url absoluteString] UTF8String]),
      base::BindOnce(^(owl::mojom::NavigationResultPtr result) {
        NSString* err = nil;
        if (result->error_description.has_value()) {
          err = @(result->error_description.value().c_str());
        }
        OWLNavigationResult* r =
            [OWLNavigationResult resultWithSuccess:result->success
                                    httpStatusCode:result->http_status_code
                                  errorDescription:err];
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(r);
        });
      }));
}

- (void)goBackWithCompletion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->GoBack(base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

- (void)goForwardWithCompletion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->GoForward(base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

- (void)reloadWithCompletion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->Reload(base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

- (void)stopWithCompletion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->Stop(base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

- (void)getPageContentWithCompletion:(void (^)(NSString*))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->GetPageContent(
        base::BindOnce(^(const std::string& content) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(@(content.c_str()));
          });
        }));
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(@""); });
  }
}

- (void)getPageInfoWithCompletion:(void (^)(OWLPageInfo*))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->GetPageInfo(
        base::BindOnce(^(owl::mojom::PageInfoPtr info) {
          OWLPageInfo* i =
              [OWLPageInfo infoWithTitle:@(info->title.c_str())
                                     url:@(info->url.c_str())
                               isLoading:info->is_loading
                               canGoBack:info->can_go_back
                              canGoForward:info->can_go_forward];
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(i);
          });
        }));
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion([OWLPageInfo infoWithTitle:@"" url:@""
                                 isLoading:NO canGoBack:NO canGoForward:NO]);
    });
  }
}

- (void)updateViewGeometry:(CGSize)sizeInPixels
               scaleFactor:(CGFloat)scaleFactor
                completion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->UpdateViewGeometry(
        gfx::Size(sizeInPixels.width, sizeInPixels.height),
        scaleFactor,
        base::BindOnce(^{
          dispatch_async(dispatch_get_main_queue(), completion);
        }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

- (void)setVisible:(BOOL)visible completion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->SetVisible(visible, base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

- (void)closeWithCompletion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->Close(base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

@end
