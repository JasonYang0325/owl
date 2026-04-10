// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLMojoThread.h"

#include "base/message_loop/message_pump_type.h"
#include "base/task/single_thread_task_executor.h"
#include "base/threading/thread.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/core/embedder/scoped_ipc_support.h"
#include "third_party/owl/bridge/owl_bridge_api.h"  // g_owl_bridge_initialized

@implementation OWLMojoThread {
  std::unique_ptr<base::SingleThreadTaskExecutor> _main_executor;
  std::unique_ptr<base::Thread> _io_thread;
  std::unique_ptr<mojo::core::ScopedIPCSupport> _ipc_support;
  BOOL _started;
}

+ (instancetype)shared {
  static OWLMojoThread* instance = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [[OWLMojoThread alloc] initPrivate];
  });
  return instance;
}

- (instancetype)initPrivate {
  self = [super init];
  if (self) {
    _started = NO;
  }
  return self;
}

- (void)ensureStarted {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Phase 25 awareness: if OWLBridge_Initialize() already ran,
    // it set up mojo::core::Init() + TaskExecutor + IO thread + IPC support.
    // Skip all init to avoid double-init (mojo::core::Init is NOT idempotent).
    if (g_owl_bridge_initialized != 0) {
      _started = YES;
      return;
    }

    // Standalone path (tests or non-Phase-25 usage):
    mojo::core::Init();

    if (!base::SingleThreadTaskRunner::HasCurrentDefault()) {
      _main_executor = std::make_unique<base::SingleThreadTaskExecutor>(
          base::MessagePumpType::NS_RUNLOOP);
    }

    _io_thread = std::make_unique<base::Thread>("OWLMojoIO");
    base::Thread::Options options(base::MessagePumpType::IO, 0);
    _started = _io_thread->StartWithOptions(std::move(options));

    if (_started) {
      _ipc_support = std::make_unique<mojo::core::ScopedIPCSupport>(
          _io_thread->task_runner(),
          mojo::core::ScopedIPCSupport::ShutdownPolicy::CLEAN);
    }
  });
}

- (BOOL)isStarted {
  return _started;
}

@end
