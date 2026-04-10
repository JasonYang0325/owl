// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_MOJO_THREAD_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_MOJO_THREAD_H_

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Singleton managing the Mojo runtime and IO thread.
/// All mojo::Remote operations must be PostTask'd to this thread.
__attribute__((visibility("default")))
@interface OWLMojoThread : NSObject

/// Returns the shared instance.
+ (instancetype)shared;

/// Ensures Mojo is initialized and IO thread is started.
/// Safe to call multiple times (dispatch_once internally).
- (void)ensureStarted;

/// Whether Mojo has been initialized.
@property(nonatomic, readonly) BOOL isStarted;

/// Cannot be instantiated directly. Use +shared.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_MOJO_THREAD_H_
