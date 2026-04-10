// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_CLIENT_OWL_INPUT_TRANSLATOR_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_INPUT_TRANSLATOR_H_

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// OWL modifier bitmask constants (matching owl_input_types.mojom).
enum {
  kOWLModifierShift        = 0x01,
  kOWLModifierControl      = 0x02,
  kOWLModifierAlt          = 0x04,
  kOWLModifierMeta         = 0x08,
  kOWLModifierCapsLock     = 0x10,
  kOWLModifierIsAutoRepeat = 0x20,
  kOWLModifierLeftButton   = 0x40,
  kOWLModifierMiddleButton = 0x80,
  kOWLModifierRightButton  = 0x100,
};

/// Pure-function translator: NSEvent → OWL input data.
/// All methods are class methods with no side effects.
__attribute__((visibility("default")))
@interface OWLInputTranslator : NSObject

/// Flip y coordinate: macOS bottom-left → Chromium top-left.
+ (float)flipY:(float)y viewHeight:(CGFloat)viewHeight;

/// Convert macOS modifier flags to OWL modifier bitmask.
/// Pass the NSEvent to capture isARepeat.
/// pressedButtons: bitmask from [NSEvent pressedMouseButtons] or test-injected value.
+ (uint32_t)modifiersFromNSEventFlags:(NSEventModifierFlags)flags
                              nsEvent:(nullable NSEvent*)event
                       pressedButtons:(NSUInteger)pressedButtons;

/// Convert OWL keyboard modifier bitmask back to NSEventModifierFlags.
/// Note: mouse button bits (kOWLModifierLeftButton etc.) and kOWLModifierIsAutoRepeat
/// are silently dropped — they have no NSEventModifierFlags equivalent.
+ (NSEventModifierFlags)nsModifierFlagsFromOWLModifiers:(uint32_t)modifiers;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_CLIENT_OWL_INPUT_TRANSLATOR_H_
