// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"

#import "third_party/owl/bridge/OWLBridgeWebView.h"

#include "base/functional/bind.h"
#include "base/memory/ptr_util.h"
#include "base/task/sequenced_task_runner.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "third_party/owl/mojom/browser_context.mojom.h"
#include "third_party/owl/mojom/web_view.mojom.h"

namespace {

struct ContextMojoState {
  mojo::Remote<owl::mojom::BrowserContextHost> remote;
  // Task runner the remote was bound on (captured at bind time).
  scoped_refptr<base::SequencedTaskRunner> bound_runner;
};

}  // namespace

@implementation OWLBridgeBrowserContext {
  ContextMojoState* _state;
}

- (nullable instancetype)initWithMojoPipe:(uint64_t)pipeHandle {
  self = [super init];
  if (!self) return nil;

  _state = new ContextMojoState();
  mojo::ScopedMessagePipeHandle pipe{mojo::MessagePipeHandle{pipeHandle}};
  _state->remote.Bind(
      mojo::PendingRemote<owl::mojom::BrowserContextHost>{
          std::move(pipe), 0});
  _state->bound_runner = base::SequencedTaskRunner::GetCurrentDefault();

  return self;
}

- (void)dealloc {
  ContextMojoState* state = _state;
  _state = nullptr;
  if (!state) return;

  auto runner = state->bound_runner;
  if (runner && !runner->RunsTasksInCurrentSequence()) {
    // WrapUnique ensures deletion even if PostTask is dropped (IO thread stopped).
    runner->PostTask(FROM_HERE,
                     base::BindOnce([](std::unique_ptr<ContextMojoState>) {},
                                    base::WrapUnique(state)));
  } else {
    delete state;  // Already on correct thread, or no runner available.
  }
}

- (void)createWebViewWithDelegate:(id<OWLWebViewDelegate>)delegate
                       completion:(void (^)(OWLBridgeWebView*,
                                           NSError*))completion {
  if (!_state || !_state->remote.is_connected()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil,
          [NSError errorWithDomain:@"OWLBridge" code:100
                          userInfo:@{NSLocalizedDescriptionKey:
                              @"Context not connected"}]);
    });
    return;
  }

  // Create observer pipe pair: remote end goes to Host, receiver end to WebView.
  mojo::MessagePipe observer_pipe;

  uint64_t observer_receiver_handle =
      observer_pipe.handle1.release().value();

  _state->remote->CreateWebView(
      mojo::PendingRemote<owl::mojom::WebViewObserver>{
          std::move(observer_pipe.handle0), 0},
      base::BindOnce(^(uint64_t webview_id,
                       mojo::PendingRemote<owl::mojom::WebViewHost> web_view) {
        if (!web_view.is_valid() || webview_id == 0) {
          mojo::ScopedMessagePipeHandle cleanup{
              mojo::MessagePipeHandle{observer_receiver_handle}};
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil,
                [NSError errorWithDomain:@"OWLBridge" code:102
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Failed to create web view"}]);
          });
          return;
        }

        OWLBridgeWebView* view = [[OWLBridgeWebView alloc]
            initWithMojoPipe:web_view.PassPipe().release().value()
                observerPipe:observer_receiver_handle
                    delegate:delegate];
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(view, nil);
        });
      }));
}

- (void)destroyWithCompletion:(void (^)(void))completion {
  if (_state && _state->remote.is_connected()) {
    _state->remote->Destroy(base::BindOnce(^{
      dispatch_async(dispatch_get_main_queue(), completion);
    }));
  } else {
    dispatch_async(dispatch_get_main_queue(), completion);
  }
}

@end
