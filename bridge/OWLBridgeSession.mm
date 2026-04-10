// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeSession.h"

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"
#import "third_party/owl/bridge/OWLMojoThread.h"

#include "base/functional/bind.h"
#include "base/memory/ptr_util.h"
#include "base/task/sequenced_task_runner.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/platform/platform_channel_endpoint.h"
#include "mojo/public/cpp/platform/platform_handle.h"
#include "mojo/public/cpp/system/invitation.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "third_party/owl/mojom/browser_context.mojom.h"
#include "third_party/owl/mojom/owl_types.mojom.h"
#include "third_party/owl/mojom/session.mojom.h"

namespace {

// C++ state — Remote has sequence affinity and must be destroyed on the
// thread it was bound on.
struct SessionMojoState {
  mojo::Remote<owl::mojom::SessionHost> remote;
  // Task runner the remote was bound on (captured at bind time).
  scoped_refptr<base::SequencedTaskRunner> bound_runner;

  ~SessionMojoState() = default;
};

}  // namespace

@implementation OWLBridgeSession {
  SessionMojoState* _state;  // Owned, deleted on IO thread in dealloc.
}
@synthesize delegate = _delegate;

- (nullable instancetype)initWithMojoPipe:(uint64_t)pipeHandle {
  self = [super init];
  if (!self) return nil;

  [[OWLMojoThread shared] ensureStarted];

  // Create state on IO thread.
  _state = new SessionMojoState();

  // Bind the remote on the current thread (must be called from IO thread
  // context, or the remote will check sequence affinity).
  // For simplicity in this initial implementation, we bind on the current
  // thread. The test fixture ensures this is the task environment thread.
  mojo::ScopedMessagePipeHandle pipe_handle{
      mojo::MessagePipeHandle{pipeHandle}};
  _state->remote.Bind(
      mojo::PendingRemote<owl::mojom::SessionHost>{
          std::move(pipe_handle), 0});
  _state->bound_runner = base::SequencedTaskRunner::GetCurrentDefault();

  __weak OWLBridgeSession* weakSelf = self;
  _state->remote.set_disconnect_handler(base::BindOnce(^{
    dispatch_async(dispatch_get_main_queue(), ^{
      OWLBridgeSession* strongSelf = weakSelf;
      if (strongSelf &&
          [strongSelf->_delegate
              respondsToSelector:@selector(sessionDidDisconnect)]) {
        [strongSelf->_delegate sessionDidDisconnect];
      }
    });
  }));

  return self;
}

- (nullable instancetype)initWithTransportFD:(int)fd {
  self = [super init];
  if (!self) {
    close(fd);
    return nil;
  }

  [[OWLMojoThread shared] ensureStarted];
  _state = new SessionMojoState();

  // Accept the invitation from the host process on this FD.
  mojo::IncomingInvitation invitation = mojo::IncomingInvitation::Accept(
      mojo::PlatformChannelEndpoint(
          mojo::PlatformHandle(base::ScopedFD(fd))));

  mojo::ScopedMessagePipeHandle pipe_handle =
      invitation.ExtractMessagePipe(0);
  if (!pipe_handle.is_valid()) {
    delete _state;
    _state = nullptr;
    return nil;
  }

  _state->remote.Bind(
      mojo::PendingRemote<owl::mojom::SessionHost>{
          std::move(pipe_handle), 0});
  _state->bound_runner = base::SequencedTaskRunner::GetCurrentDefault();

  __weak OWLBridgeSession* weakSelf = self;
  _state->remote.set_disconnect_handler(base::BindOnce(^{
    dispatch_async(dispatch_get_main_queue(), ^{
      OWLBridgeSession* strongSelf = weakSelf;
      if (strongSelf &&
          [strongSelf->_delegate
              respondsToSelector:@selector(sessionDidDisconnect)]) {
        [strongSelf->_delegate sessionDidDisconnect];
      }
    });
  }));

  return self;
}

- (void)dealloc {
  SessionMojoState* state = _state;
  _state = nullptr;
  if (!state) return;

  auto runner = state->bound_runner;
  if (runner && !runner->RunsTasksInCurrentSequence()) {
    // WrapUnique ensures deletion even if PostTask is dropped (IO thread stopped).
    runner->PostTask(FROM_HERE,
                     base::BindOnce([](std::unique_ptr<SessionMojoState>) {},
                                    base::WrapUnique(state)));
  } else {
    delete state;  // Already on correct thread, or no runner available.
  }
}

- (void)getHostInfoWithCompletion:(void (^)(NSString*, NSString*,
                                            uint16_t, NSError*))completion {
  if (!_state || !_state->remote.is_connected()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil, nil, 0,
                 [NSError errorWithDomain:@"OWLBridge" code:100
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"Session not connected"}]);
    });
    return;
  }

  _state->remote->GetHostInfo(base::BindOnce(
      ^(const std::string& version, const std::string& user_data_dir,
        uint16_t devtools_port) {
        NSString* v = @(version.c_str());
        NSString* d = @(user_data_dir.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(v, d, devtools_port, nil);
        });
      }));
}

- (void)createBrowserContextWithPartition:(nullable NSString*)partitionName
                             offTheRecord:(BOOL)offTheRecord
                               completion:(void (^)(OWLBridgeBrowserContext*,
                                                    NSError*))completion {
  if (!_state || !_state->remote.is_connected()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil,
                 [NSError errorWithDomain:@"OWLBridge" code:100
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"Session not connected"}]);
    });
    return;
  }

  auto config = owl::mojom::ProfileConfig::New();
  if (partitionName) {
    config->partition_name = std::string([partitionName UTF8String]);
  }
  config->off_the_record = offTheRecord;

  _state->remote->CreateBrowserContext(
      std::move(config),
      base::BindOnce(
          ^(mojo::PendingRemote<owl::mojom::BrowserContextHost> context) {
            if (!context.is_valid()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil,
                    [NSError errorWithDomain:@"OWLBridge" code:101
                                   userInfo:@{NSLocalizedDescriptionKey:
                                       @"Failed to create browser context"}]);
              });
              return;
            }

            OWLBridgeBrowserContext* ctx = [[OWLBridgeBrowserContext alloc]
                initWithMojoPipe:context.PassPipe().release().value()];
            dispatch_async(dispatch_get_main_queue(), ^{
              completion(ctx, nil);
            });
          }));
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
  if (!_state || !_state->remote.is_connected()) {
    dispatch_async(dispatch_get_main_queue(), completion);
    return;
  }

  _state->remote->Shutdown(base::BindOnce(^{
    dispatch_async(dispatch_get_main_queue(), completion);
  }));
}

@end
