// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/client/OWLInputTranslator.h"

@implementation OWLInputTranslator

+ (float)flipY:(float)y viewHeight:(CGFloat)viewHeight {
  return (float)(viewHeight - y);
}

+ (uint32_t)modifiersFromNSEventFlags:(NSEventModifierFlags)flags
                              nsEvent:(nullable NSEvent*)event
                       pressedButtons:(NSUInteger)pressedButtons {
  uint32_t mods = 0;

  if (flags & NSEventModifierFlagShift)    mods |= kOWLModifierShift;
  if (flags & NSEventModifierFlagControl)  mods |= kOWLModifierControl;
  if (flags & NSEventModifierFlagOption)   mods |= kOWLModifierAlt;
  if (flags & NSEventModifierFlagCommand)  mods |= kOWLModifierMeta;
  if (flags & NSEventModifierFlagCapsLock) mods |= kOWLModifierCapsLock;

  // Mouse button state (injected for testability).
  if (pressedButtons & (1 << 0)) mods |= kOWLModifierLeftButton;
  if (pressedButtons & (1 << 1)) mods |= kOWLModifierRightButton;
  if (pressedButtons & (1 << 2)) mods |= kOWLModifierMiddleButton;

  // Auto-repeat for key events.
  if (event) {
    NSEventType type = event.type;
    if (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp) {
      if (event.isARepeat) {
        mods |= kOWLModifierIsAutoRepeat;
      }
    }
  }

  return mods;
}

+ (NSEventModifierFlags)nsModifierFlagsFromOWLModifiers:(uint32_t)modifiers {
  NSEventModifierFlags flags = 0;

  if (modifiers & kOWLModifierShift)    flags |= NSEventModifierFlagShift;
  if (modifiers & kOWLModifierControl)  flags |= NSEventModifierFlagControl;
  if (modifiers & kOWLModifierAlt)      flags |= NSEventModifierFlagOption;
  if (modifiers & kOWLModifierMeta)     flags |= NSEventModifierFlagCommand;
  if (modifiers & kOWLModifierCapsLock) flags |= NSEventModifierFlagCapsLock;

  return flags;
}

@end
