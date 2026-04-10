// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_BROWSER_CONTEXT_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_BROWSER_CONTEXT_H_

#import <Foundation/Foundation.h>

#if __has_include("third_party/owl/bridge/OWLBridgeTypes.h")
#import "third_party/owl/bridge/OWLBridgeTypes.h"
#else
#import "OWLBridgeTypes.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@class OWLBridgeWebView;
@protocol OWLWebViewDelegate;

__attribute__((visibility("default")))
@interface OWLBridgeBrowserContext : NSObject

/// Create from an existing Mojo pipe (used internally and for testing).
- (nullable instancetype)initWithMojoPipe:(uint64_t)pipeHandle;
- (instancetype)init NS_UNAVAILABLE;

/// Create a WebView. delegate is required.
- (void)createWebViewWithDelegate:(id<OWLWebViewDelegate>)delegate
                       completion:(void (^)(OWLBridgeWebView* _Nullable,
                                           NSError* _Nullable))completion;

/// Destroy this context.
- (void)destroyWithCompletion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_BROWSER_CONTEXT_H_
