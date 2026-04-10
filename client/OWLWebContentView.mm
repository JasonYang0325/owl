// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/client/OWLWebContentView.h"

#import <QuartzCore/QuartzCore.h>

@implementation OWLWebContentView {
  CALayer<OWLRemoteLayerHost>* __strong _layerHost;
  uint32_t _currentContextId;
  __weak id<OWLWebContentViewDelegate> _delegate;
  OWLRemoteLayerFactory _factory;
}

@synthesize currentContextId = _currentContextId;

- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(nullable id<OWLWebContentViewDelegate>)delegate {
  return [self initWithFrame:frame delegate:delegate remoteLayerFactory:nil];
}

- (instancetype)initWithFrame:(NSRect)frame
                     delegate:(nullable id<OWLWebContentViewDelegate>)delegate
            remoteLayerFactory:(nullable OWLRemoteLayerFactory)factory {
  self = [super initWithFrame:frame];
  if (self) {
    _delegate = delegate;
    _factory = [factory copy];
    // Force layer-backed mode with our custom backing layer.
    CALayer* backingLayer = [CALayer layer];
    backingLayer.geometryFlipped = YES;
    self.layer = backingLayer;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
  }
  return self;
}

- (CALayer*)makeBackingLayer {
  CALayer* layer = [CALayer layer];
  layer.geometryFlipped = YES;
  return layer;
}

- (void)updateRenderSurfaceWithContextId:(uint32_t)contextId
                               pixelSize:(CGSize)pixelSize
                             scaleFactor:(CGFloat)scaleFactor {
  // Suppress implicit animations.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  if (contextId == 0) {
    [self clearRenderSurfaceInternal];
    [CATransaction commit];
    return;
  }

  // Convert pixel size to DIP.
  CGFloat scale = (scaleFactor > 0) ? scaleFactor : 1.0;
  CGSize dipSize = CGSizeMake(pixelSize.width / scale,
                              pixelSize.height / scale);

  if (_currentContextId == contextId) {
    // Same context — update bounds only.
    _layerHost.bounds = CGRectMake(0, 0, dipSize.width, dipSize.height);
    _layerHost.contentsScale = scale;
    [CATransaction commit];
    return;
  }

  // New context — replace layer host.
  [_layerHost removeFromSuperlayer];

  if (_factory) {
    _layerHost = _factory(contextId);
  } else {
    // BH-023: Test-only fallback. Production code uses OWLRemoteLayerView
    // (bridge/OWLRemoteLayerView.mm) which creates a real CALayerHost via
    // ui/base/cocoa/remote_layer_api.h. This nil path should only be
    // reached in tests that don't supply a remoteLayerFactory.
    NSLog(@"OWLWebContentView: no remoteLayerFactory provided — "
          @"test-only path, production should use OWLRemoteLayerView");
    _layerHost = nil;
  }

  if (_layerHost) {
    _layerHost.anchorPoint = CGPointZero;
    _layerHost.position = CGPointZero;
    _layerHost.bounds = CGRectMake(0, 0, dipSize.width, dipSize.height);
    _layerHost.contentsScale = scale;
    _layerHost.autoresizingMask =
        kCALayerMaxXMargin | kCALayerMaxYMargin;
    [self.layer addSublayer:_layerHost];
  }

  _currentContextId = contextId;
  [CATransaction commit];
}

- (void)clearRenderSurface {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self clearRenderSurfaceInternal];
  [CATransaction commit];
}

- (void)clearRenderSurfaceInternal {
  [_layerHost removeFromSuperlayer];
  _layerHost = nil;
  _currentContextId = 0;
}

- (BOOL)hasRenderSurface {
  return _currentContextId != 0 && _layerHost != nil;
}

- (void)setFrameSize:(NSSize)newSize {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [super setFrameSize:newSize];
  [CATransaction commit];

  CGFloat scale = self.window.backingScaleFactor;
  if (scale <= 0) scale = 1.0;
  [_delegate webContentView:self
      didResizeToPixelSize:CGSizeMake(newSize.width * scale,
                                      newSize.height * scale)
               scaleFactor:scale];
}

- (void)viewDidChangeBackingProperties {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [super viewDidChangeBackingProperties];
  [CATransaction commit];

  CGFloat scale = self.window.backingScaleFactor;
  if (scale <= 0) scale = 1.0;
  CGSize pixelSize = CGSizeMake(self.bounds.size.width * scale,
                                self.bounds.size.height * scale);
  [_delegate webContentView:self
      didResizeToPixelSize:pixelSize
               scaleFactor:scale];
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
  [super viewWillMoveToWindow:newWindow];
  if (newWindow == nil) {
    [self clearRenderSurface];
  }
}

- (void)dealloc {
  [self clearRenderSurfaceInternal];
}

@end
