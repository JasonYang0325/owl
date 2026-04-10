// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_SESSION_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_SESSION_H_

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OWLBridgeBrowserContext;

@protocol OWLSessionDelegate <NSObject>
@optional
- (void)sessionDidShutdown;
- (void)sessionDidDisconnect;
@end

/// ObjC++ wrapper around mojo::Remote<owl::mojom::SessionHost>.
/// All public methods are called on the main thread.
/// Internally, Mojo calls are dispatched to the IO thread.
__attribute__((visibility("default")))
@interface OWLBridgeSession : NSObject

@property(weak, nonatomic, nullable) id<OWLSessionDelegate> delegate;

/// Create a session connected to an existing Mojo message pipe.
/// Used for in-process testing where both ends share the same Mojo IPC context.
- (nullable instancetype)initWithMojoPipe:(uint64_t)pipeHandle;

/// Create a session by accepting a Mojo invitation on a transport FD.
/// Used for cross-process connections (OWLProcessLauncher → owl-host).
/// The FD is consumed (closed) by this method regardless of success/failure.
- (nullable instancetype)initWithTransportFD:(int)fd;

- (instancetype)init NS_UNAVAILABLE;

/// Get host configuration.
- (void)getHostInfoWithCompletion:(void (^)(NSString* _Nullable version,
                                            NSString* _Nullable userDataDir,
                                            uint16_t devtoolsPort,
                                            NSError* _Nullable error))completion;

/// Create a browser context.
- (void)createBrowserContextWithPartition:(nullable NSString*)partitionName
                             offTheRecord:(BOOL)offTheRecord
                               completion:(void (^)(OWLBridgeBrowserContext* _Nullable context,
                                                    NSError* _Nullable error))completion;

/// Shutdown (cascading destroy).
- (void)shutdownWithCompletion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_SESSION_H_
