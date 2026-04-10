// Copyright 2026 AntlerAI. All rights reserved.

#import "third_party/owl/bridge/OWLRemoteLayerView.h"
#import <QuartzCore/QuartzCore.h>
#import "third_party/owl/bridge/owl_bridge_api.h"
#import "third_party/owl/client/OWLInputTranslator.h"

// Private CALayerHost API — same declaration as ui/base/cocoa/remote_layer_api.h
@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

// Phase 31 IME action types — what happened during interpretKeyEvents:
typedef NS_ENUM(int, OWLImeAction) {
  OWLImeActionNone,
  OWLImeActionSetComposition,
  OWLImeActionCommit,
  OWLImeActionInsertChar,
};

@implementation OWLRemoteLayerView {
  CALayerHost* _layerHost;
  CALayer* _flippedContainer;
  uint32_t _currentContextId;
  NSTrackingArea* _trackingArea;

  // Phase 31: IME state
  BOOL _handlingKeyDown;
  BOOL _hasMarkedText;
  BOOL _imeHandledLastKeyDown;  // true if last keyDown was consumed by IME (no RawKeyDown sent)
  NSString* _markedText;
  NSRange _markedRange;
  NSRange _markedTextSelectedRange;
  NSRange _selectionRange;  // Tracks caret/selection position for IME; {0,0} = valid insertion point
  NSRect _caretRect;  // view-local DIP, top-left origin (from Host)
  BOOL _caretRectValid;
  OWLImeAction _imeAction;
  NSString* _pendingInsertText;
  int32_t _pendingReplacementStart;
  int32_t _pendingReplacementEnd;
  SEL _pendingEditCommand;
}
@synthesize scaleChangeHandler = _scaleChangeHandler;
@synthesize webviewId = _webviewId;

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    // Layer-hosting mode: set layer BEFORE wantsLayer so we own the layer tree.
    CALayer* rootLayer = [[CALayer alloc] init];
    rootLayer.opaque = YES;
    rootLayer.backgroundColor = [NSColor whiteColor].CGColor;
    self.layer = rootLayer;
    self.wantsLayer = YES;

    // Flipped container — matches Chromium's DisplayCALayerTree pattern.
    _flippedContainer = [[CALayer alloc] init];
    _flippedContainer.geometryFlipped = YES;
    _flippedContainer.anchorPoint = CGPointZero;
    _flippedContainer.frame = rootLayer.bounds;
    _flippedContainer.autoresizingMask =
        kCALayerWidthSizable | kCALayerHeightSizable;
    [self.layer addSublayer:_flippedContainer];

    _markedRange = NSMakeRange(NSNotFound, 0);
    _markedTextSelectedRange = NSMakeRange(0, 0);
    _selectionRange = NSMakeRange(0, 0);  // Valid insertion point at position 0
  }
  return self;
}

- (void)updateWithContextId:(uint32_t)contextId
                 pixelWidth:(uint32_t)pixelWidth
                pixelHeight:(uint32_t)pixelHeight
                scaleFactor:(float)scaleFactor {
  if (contextId == 0) {
    [_layerHost removeFromSuperlayer];
    _layerHost = nil;
    _currentContextId = 0;
    return;
  }

  // Phase 35: Same contextId — refresh contentsScale without rebuilding CALayerHost.
  if (contextId == _currentContextId) {
    CGFloat scale = (scaleFactor >= 1.0f)
        ? (CGFloat)scaleFactor : self.window.backingScaleFactor;
    if (scale <= 0) scale = 2.0;
    if (_layerHost && _layerHost.contentsScale != scale) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      _layerHost.contentsScale = scale;
      [CATransaction commit];
    }
    return;
  }

  _currentContextId = contextId;

  // Phase 35: Scale priority — use passed scaleFactor when valid, fall back to window.
  CGFloat scale = (scaleFactor >= 1.0f)
      ? (CGFloat)scaleFactor : self.window.backingScaleFactor;
  if (scale <= 0) scale = 2.0;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  CALayerHost* newHost = [[CALayerHost alloc] init];
  newHost.anchorPoint = CGPointZero;
  newHost.contextId = contextId;
  newHost.autoresizingMask = kCALayerMaxXMargin | kCALayerMaxYMargin;
  newHost.contentsScale = scale;

  [_flippedContainer addSublayer:newHost];
  [_layerHost removeFromSuperlayer];
  _layerHost = newHost;

  [CATransaction commit];

  NSLog(@"[OWL] OWLRemoteLayerView: attached contextId=%u (layer-hosting mode)",
        contextId);
}

- (void)updateCaretRect:(NSRect)rect {
  _caretRect = rect;
  _caretRectValid = YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self _updateContentsScale];
}

- (void)layout {
  [super layout];
  [self _updateContentsScale];
}

- (void)_updateContentsScale {
  CGFloat scale = self.window.backingScaleFactor;
  // Phase 35: Only treat truly invalid values as needing a default, not legit 1.0.
  if (scale <= 0) scale = 2.0;
  if (self.layer.contentsScale != scale) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contentsScale = scale;
    _flippedContainer.contentsScale = scale;
    if (_layerHost) _layerHost.contentsScale = scale;
    [CATransaction commit];
  }
}

// Phase 35: Cross-screen DPI monitoring — fires when window moves between displays.
- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self _updateContentsScale];
  CGFloat scale = self.window.backingScaleFactor;
  if (scale <= 0) scale = 2.0;
  if (_scaleChangeHandler) {
    _scaleChangeHandler(scale, self.bounds.size);
  }
}

// MARK: - Accessibility (XCUITest support)

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }

// MARK: - Input Event Handling

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)becomeFirstResponder {
  NSLog(@"[OWL] OWLRemoteLayerView becomeFirstResponder");
  // Activate input context so macOS IME system connects to this view.
  // Without this, some IME implementations may not start composition.
  [self.inputContext activate];
  return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
  NSLog(@"[OWL] OWLRemoteLayerView resignFirstResponder");
  // Cancel any ongoing composition when losing focus.
  if (_hasMarkedText) {
    [self.inputContext discardMarkedText];
    _hasMarkedText = NO;
    _markedText = nil;
    _markedRange = NSMakeRange(NSNotFound, 0);
    OWLBridge_ImeFinishComposing(_webviewId);
  }
  [self.inputContext deactivate];
  return [super resignFirstResponder];
}

// Phase 28: Intercept Tab/Shift+Tab before SwiftUI grabs them.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
  if (event.keyCode == 48 /* kVK_Tab */) {
    NSEventModifierFlags mods = event.modifierFlags &
        NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods == 0 || mods == NSEventModifierFlagShift) {
      [self keyDown:event];
      return YES;
    }
  }
  return [super performKeyEquivalent:event];
}

- (NSView*)hitTest:(NSPoint)point {
  NSPoint local = [self convertPoint:point fromView:self.superview];
  if (NSPointInRect(local, self.bounds)) return self;
  return nil;
}

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) [self removeTrackingArea:_trackingArea];
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                   NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

// MARK: - Mouse Events

- (void)mouseDown:(NSEvent*)e {
  if (self.window.firstResponder != self) {
    [self.window makeFirstResponder:self];
  }
  [self _sendMouse:e type:0 button:1];
}
- (void)mouseUp:(NSEvent*)e         { [self _sendMouse:e type:1 button:1]; }
- (void)mouseMoved:(NSEvent*)e      { [self _sendMouse:e type:2 button:0]; }
- (void)mouseDragged:(NSEvent*)e    { [self _sendMouse:e type:2 button:1]; }
- (void)mouseEntered:(NSEvent*)e    { [self _sendMouse:e type:3 button:0]; }
- (void)mouseExited:(NSEvent*)e     { [self _sendMouse:e type:4 button:0]; }
- (void)rightMouseDown:(NSEvent*)e  { [self _sendMouse:e type:0 button:2]; }
- (void)rightMouseUp:(NSEvent*)e    { [self _sendMouse:e type:1 button:2]; }
- (void)rightMouseDragged:(NSEvent*)e { [self _sendMouse:e type:2 button:2]; }
- (void)otherMouseDown:(NSEvent*)e  { [self _sendMouse:e type:0 button:3]; }
- (void)otherMouseUp:(NSEvent*)e    { [self _sendMouse:e type:1 button:3]; }
- (void)otherMouseDragged:(NSEvent*)e { [self _sendMouse:e type:2 button:3]; }

- (void)_sendMouse:(NSEvent*)event type:(int)type button:(int)button {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  float y = [OWLInputTranslator flipY:(float)local.y
                            viewHeight:self.bounds.size.height];
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:event.modifierFlags
                        nsEvent:event
                 pressedButtons:NSEvent.pressedMouseButtons];
  NSPoint screen = NSZeroPoint;
  if (self.window) {
    screen = [self.window convertPointToScreen:event.locationInWindow];
    screen.y = NSScreen.mainScreen.frame.size.height - screen.y;
  }
  NSLog(@"[OWL] _sendMouse type=%d button=%d x=%.0f y=%.0f", type, button, local.x, y);
  OWLBridge_SendMouseEvent(_webviewId, type, button,
                            (float)local.x, y,
                            (float)screen.x, (float)screen.y,
                            mods, (int)event.clickCount,
                            event.timestamp);
}

// MARK: - Keyboard Events (Phase 31: two-phase model with IME support)

- (void)keyDown:(NSEvent*)e {
  _handlingKeyDown = YES;
  _imeAction = OWLImeActionNone;
  _pendingInsertText = nil;
  _pendingEditCommand = NULL;
  _imeHandledLastKeyDown = NO;

  NSLog(@"[OWL-IME] keyDown: keyCode=%d chars='%@' isFirstResponder=%d inputContext=%@",
        (int)e.keyCode, e.characters,
        (self.window.firstResponder == self),
        self.inputContext);

  // Phase 1: let macOS IME framework process the event.
  // IME may call setMarkedText:, insertText:, or doCommandBySelector:.
  [self interpretKeyEvents:@[e]];

  NSLog(@"[OWL-IME] keyDown Phase2: imeAction=%d pendingText='%@' hasMarkedText=%d",
        _imeAction, _pendingInsertText, _hasMarkedText);

  // Phase 2: dispatch based on what happened.
  switch (_imeAction) {
    case OWLImeActionSetComposition:
      // Already sent via OWLBridge_ImeSetComposition in setMarkedText:.
      _imeHandledLastKeyDown = YES;
      break;

    case OWLImeActionCommit:
      // IME confirmed composition → send commit with replacement range.
      _imeHandledLastKeyDown = YES;
      OWLBridge_ImeCommitText(_webviewId, _pendingInsertText.UTF8String,
          _pendingReplacementStart, _pendingReplacementEnd);
      break;

    case OWLImeActionInsertChar:
      // Plain English character, no IME composition → original key event flow.
      // Preserves JS keydown/keyup semantics.
      _imeHandledLastKeyDown = NO;
      [self _sendKey:e type:0];  // RawKeyDown
      if (e.characters.length > 0) {
        unichar ch = [e.characters characterAtIndex:0];
        if (ch >= 0x20 && ch != 0x7F) {
          [self _sendKey:e type:2];  // Char
        }
      }
      break;

    case OWLImeActionNone:
      // interpretKeyEvents: didn't produce insertText or setMarkedText.
      _imeHandledLastKeyDown = NO;
      if (_pendingEditCommand) {
        [self _sendKey:e type:0];  // RawKeyDown for edit commands
      } else if (e.characters.length == 0 ||
                 [e.characters characterAtIndex:0] < 0x20 ||
                 [e.characters characterAtIndex:0] == 0x7F) {
        [self _sendKey:e type:0];  // Control character
      }
      break;
  }

  _handlingKeyDown = NO;
}

- (void)keyUp:(NSEvent*)e {
  // Don't send KeyUp if keyDown was consumed by IME — no matching RawKeyDown was sent.
  if (!_imeHandledLastKeyDown) {
    [self _sendKey:e type:1];
  }
}

- (void)_sendKey:(NSEvent*)event type:(int)type {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:event.modifierFlags
                        nsEvent:event
                 pressedButtons:0];
  OWLBridge_SendKeyEvent(_webviewId, type, (int)event.keyCode, mods,
                          event.characters.UTF8String,
                          event.charactersIgnoringModifiers.UTF8String,
                          event.timestamp);
}

- (void)flagsChanged:(NSEvent*)event {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:event.modifierFlags
                        nsEvent:event
                 pressedButtons:0];
  int type = (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) ? 0 : 1;
  OWLBridge_SendKeyEvent(_webviewId, type, (int)event.keyCode, mods,
                          NULL, NULL, event.timestamp);
}

// MARK: - NSTextInputClient (Phase 31: IME support)

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString* text = [string isKindOfClass:[NSAttributedString class]]
      ? [(NSAttributedString*)string string] : (NSString*)string;
  NSLog(@"[OWL-IME] insertText: '%@' replacementRange={%lu,%lu} handlingKeyDown=%d hasMarkedText=%d",
        text, (unsigned long)replacementRange.location, (unsigned long)replacementRange.length,
        _handlingKeyDown, _hasMarkedText);

  int32_t replStart = (replacementRange.location == NSNotFound) ? -1
      : (int32_t)replacementRange.location;
  int32_t replEnd = (replacementRange.location == NSNotFound) ? -1
      : (int32_t)NSMaxRange(replacementRange);

  BOOL wasComposing = _hasMarkedText;

  // Reset composition state.
  _hasMarkedText = NO;
  _markedText = nil;
  _markedRange = NSMakeRange(NSNotFound, 0);

  // Advance the logical selection position past the inserted text.
  // This ensures subsequent selectedRange calls return a valid insertion point.
  _selectionRange = NSMakeRange(_selectionRange.location + text.length, 0);

  if (_handlingKeyDown) {
    // Inside keyDown: → defer to Phase 2.
    _pendingInsertText = text;
    _pendingReplacementStart = replStart;
    _pendingReplacementEnd = replEnd;
    _imeAction = wasComposing ? OWLImeActionCommit : OWLImeActionInsertChar;
  } else {
    // Outside keyDown: (e.g. candidate click) → dispatch immediately.
    OWLBridge_ImeCommitText(_webviewId, text.UTF8String, replStart, replEnd);
  }
}

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)newSelRange
     replacementRange:(NSRange)replacementRange {
  NSString* text = [string isKindOfClass:[NSAttributedString class]]
      ? [(NSAttributedString*)string string] : (NSString*)string;
  NSLog(@"[OWL-IME] setMarkedText: '%@' selRange={%lu,%lu} replRange={%lu,%lu}",
        text, (unsigned long)newSelRange.location, (unsigned long)newSelRange.length,
        (unsigned long)replacementRange.location, (unsigned long)replacementRange.length);

  _hasMarkedText = (text.length > 0);
  _markedText = text;
  _markedRange = _hasMarkedText
      ? NSMakeRange(0, text.length) : NSMakeRange(NSNotFound, 0);
  _markedTextSelectedRange = newSelRange;
  _imeAction = OWLImeActionSetComposition;

  int32_t replStart = (replacementRange.location == NSNotFound) ? -1
      : (int32_t)replacementRange.location;
  int32_t replEnd = (replacementRange.location == NSNotFound) ? -1
      : (int32_t)NSMaxRange(replacementRange);

  // Send immediately — setMarkedText can be called multiple times per keyDown.
  OWLBridge_ImeSetComposition(_webviewId, text.UTF8String,
      (int32_t)newSelRange.location, (int32_t)NSMaxRange(newSelRange),
      replStart, replEnd);

  // Tell macOS the character coordinates changed so it re-queries
  // firstRectForCharacterRange: for IME candidate window positioning.
  [[self inputContext] invalidateCharacterCoordinates];
}

- (void)unmarkText {
  if (_hasMarkedText) {
    _hasMarkedText = NO;
    _markedText = nil;
    _markedRange = NSMakeRange(NSNotFound, 0);
    OWLBridge_ImeFinishComposing(_webviewId);
  }
}

- (BOOL)hasMarkedText { return _hasMarkedText; }

- (NSRange)markedRange { return _markedRange; }

- (NSRange)selectedRange {
  if (_hasMarkedText) {
    return NSMakeRange(_markedRange.location + _markedTextSelectedRange.location,
                       _markedTextSelectedRange.length);
  }
  // Return a valid insertion point so IME knows composition is possible.
  // {NSNotFound, 0} tells IME "no valid insertion point" and many Chinese IME
  // implementations will skip composition and insert raw characters instead.
  return _selectionRange;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(nullable NSRangePointer)actualRange {
  if (!_caretRectValid) {
    // No caret rect from Host yet — let macOS decide candidate window position.
    return NSZeroRect;
  }
  // _caretRect is view-local DIP, top-left origin (Chromium convention).
  // Convert: top-left → NSView bottom-left → window → screen.
  CGFloat viewH = self.bounds.size.height;
  NSRect flipped = NSMakeRect(_caretRect.origin.x,
      viewH - _caretRect.origin.y - _caretRect.size.height,
      MAX(_caretRect.size.width, 1), _caretRect.size.height);
  NSRect windowRect = [self convertRect:flipped toView:nil];
  NSRect screenRect = [self.window convertRectToScreen:windowRect];
  if (actualRange) *actualRange = range;
  return screenRect;
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range
                                              actualRange:(nullable NSRangePointer)actualRange {
  return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  return NSNotFound;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
  return @[NSUnderlineStyleAttributeName];
}

- (void)doCommandBySelector:(SEL)selector {
  NSLog(@"[OWL-IME] doCommandBySelector: %@", NSStringFromSelector(selector));
  _pendingEditCommand = selector;
  // Don't execute — keyDown: fallback will send the raw key event.
}

// MARK: - Scroll Wheel

- (void)scrollWheel:(NSEvent*)event {
  NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
  float y = [OWLInputTranslator flipY:(float)local.y
                            viewHeight:self.bounds.size.height];
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:event.modifierFlags
                        nsEvent:event
                 pressedButtons:0];
  NSPoint screen = NSZeroPoint;
  if (self.window) {
    screen = [self.window convertPointToScreen:event.locationInWindow];
    screen.y = NSScreen.mainScreen.frame.size.height - screen.y;
  }
  int owlPhase = 0, owlMomentum = 0;
  NSEventPhase phase = event.phase;
  if (phase & NSEventPhaseBegan)          owlPhase = 1;
  else if (phase & NSEventPhaseChanged)   owlPhase = 2;
  else if (phase & NSEventPhaseEnded)     owlPhase = 3;
  else if (phase & NSEventPhaseCancelled) owlPhase = 4;
  else if (phase & NSEventPhaseMayBegin)  owlPhase = 5;
  NSEventPhase mp = event.momentumPhase;
  if (mp & NSEventPhaseBegan)          owlMomentum = 1;
  else if (mp & NSEventPhaseChanged)   owlMomentum = 2;
  else if (mp & NSEventPhaseEnded)     owlMomentum = 3;
  int deltaUnits = event.hasPreciseScrollingDeltas ? 0 : 1;
  OWLBridge_SendWheelEvent(_webviewId,
      (float)local.x, y, (float)screen.x, (float)screen.y,
      (float)event.scrollingDeltaX, (float)event.scrollingDeltaY,
      mods, owlPhase, owlMomentum, deltaUnits,
      event.timestamp);
}

@end
