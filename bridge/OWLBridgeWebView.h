// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_WEB_VIEW_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_WEB_VIEW_H_

#import <Foundation/Foundation.h>

#if __has_include("third_party/owl/bridge/OWLBridgeTypes.h")
#import "third_party/owl/bridge/OWLBridgeTypes.h"
#else
#import "OWLBridgeTypes.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@class OWLBridgeWebView;

@protocol OWLWebViewDelegate <NSObject>
@optional
- (void)webView:(OWLBridgeWebView*)webView
    didUpdatePageInfo:(OWLPageInfo*)info;
- (void)webView:(OWLBridgeWebView*)webView
    didFinishLoadWithSuccess:(BOOL)success;
- (void)webView:(OWLBridgeWebView*)webView
    didUpdateRenderSurface:(OWLRenderSurface*)surface;
- (void)webView:(OWLBridgeWebView*)webView
    didReceiveUnhandledKeyEvent:(OWLKeyEvent*)event;
@end

/// ObjC++ wrapper around mojo::Remote<owl::mojom::WebViewHost>.
__attribute__((visibility("default")))
@interface OWLBridgeWebView : NSObject

@property(weak, nonatomic, readonly, nullable) id<OWLWebViewDelegate> delegate;

/// Create from a Mojo pipe + observer receiver pipe (used internally).
- (nullable instancetype)initWithMojoPipe:(uint64_t)pipeHandle
                         observerPipe:(uint64_t)observerPipeHandle
                                 delegate:(id<OWLWebViewDelegate>)delegate;
- (instancetype)init NS_UNAVAILABLE;

- (void)navigateToURL:(NSURL*)url
           completion:(void (^)(OWLNavigationResult*))completion;
- (void)goBackWithCompletion:(void (^)(void))completion;
- (void)goForwardWithCompletion:(void (^)(void))completion;
- (void)reloadWithCompletion:(void (^)(void))completion;
- (void)stopWithCompletion:(void (^)(void))completion;
- (void)getPageContentWithCompletion:(void (^)(NSString*))completion;
- (void)getPageInfoWithCompletion:(void (^)(OWLPageInfo*))completion;
- (void)updateViewGeometry:(CGSize)sizeInPixels
               scaleFactor:(CGFloat)scaleFactor
                completion:(void (^)(void))completion;
- (void)setVisible:(BOOL)visible completion:(void (^)(void))completion;
- (void)closeWithCompletion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_WEB_VIEW_H_
