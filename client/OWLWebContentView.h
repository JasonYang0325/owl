// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_CLIENT_OWL_WEB_CONTENT_VIEW_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_WEB_CONTENT_VIEW_H_

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class OWLWebContentView;

/// Delegate for resize notifications.
@protocol OWLWebContentViewDelegate <NSObject>
- (void)webContentView:(OWLWebContentView*)view
    didResizeToPixelSize:(CGSize)pixelSize
             scaleFactor:(CGFloat)scaleFactor;
@end

/// Protocol abstracting the remote layer (for testability).
/// Production uses CALayerHost; tests use a plain CALayer.
@protocol OWLRemoteLayerHost <NSObject>
@property uint32_t contextId;
@end

/// Factory for creating remote layer host instances.
typedef CALayer<OWLRemoteLayerHost>* _Nullable (^OWLRemoteLayerFactory)(
    uint32_t contextId);

/// NSView subclass that embeds a remote CALayerHost to display
/// cross-process Chromium rendering output.
__attribute__((visibility("default")))
@interface OWLWebContentView : NSView

- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(nullable id<OWLWebContentViewDelegate>)delegate;
- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(nullable id<OWLWebContentViewDelegate>)delegate
            remoteLayerFactory:(nullable OWLRemoteLayerFactory)factory;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

/// Update the render surface. Called when OnRenderSurfaceChanged fires.
- (void)updateRenderSurfaceWithContextId:(uint32_t)contextId
                               pixelSize:(CGSize)pixelSize
                             scaleFactor:(CGFloat)scaleFactor;

/// Clear the render surface (disconnect/close/dealloc cleanup).
- (void)clearRenderSurface;

/// Whether a render surface is currently active.
@property(nonatomic, readonly) BOOL hasRenderSurface;

/// The current context ID (0 if none).
@property(nonatomic, readonly) uint32_t currentContextId;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_CLIENT_OWL_WEB_CONTENT_VIEW_H_
