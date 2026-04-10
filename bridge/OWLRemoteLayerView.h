// Copyright 2026 AntlerAI. All rights reserved.
// Thin ObjC NSView wrapper for cross-process CALayerHost embedding.
// Phase 31: Implements NSTextInputClient for IME (Chinese/Japanese/Korean) input.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_REMOTE_LAYER_VIEW_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_REMOTE_LAYER_VIEW_H_

#import <AppKit/AppKit.h>

__attribute__((visibility("default")))
@interface OWLRemoteLayerView : NSView <NSTextInputClient>

/// The webview ID this view routes input events to.
@property (nonatomic) uint64_t webviewId;

/// Update the displayed remote layer. Thread: main only.
/// @param contextId  CAContext ID from Host compositor (0 to clear)
/// @param pixelWidth  Render surface width in pixels
/// @param pixelHeight Render surface height in pixels
/// @param scaleFactor Device scale factor (e.g. 2.0 for Retina)
- (void)updateWithContextId:(uint32_t)contextId
                 pixelWidth:(uint32_t)pixelWidth
                pixelHeight:(uint32_t)pixelHeight
                scaleFactor:(float)scaleFactor;

/// Update cached caret rect (view-local DIP, top-left origin).
/// Called from C-ABI caret rect callback. Used by firstRectForCharacterRange:.
- (void)updateCaretRect:(NSRect)rect;

// Phase 35: Thread: main only (called from viewDidChangeBackingProperties).
@property (nonatomic, copy, nullable) void (^scaleChangeHandler)(CGFloat newScale, CGSize dipSize);

@end

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_REMOTE_LAYER_VIEW_H_
