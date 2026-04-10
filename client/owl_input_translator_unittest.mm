// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/client/OWLInputTranslator.h"

#include <cmath>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// --- Y coordinate flipping ---

TEST(OWLInputTranslatorTest, FlipYNormal) {
  // View height 600, point at y=100 (from bottom).
  // Flipped = 600 - 100 = 500 (from top).
  EXPECT_FLOAT_EQ([OWLInputTranslator flipY:100.0f viewHeight:600.0], 500.0f);
}

TEST(OWLInputTranslatorTest, FlipYOrigin) {
  // y=0 (bottom) → viewHeight (top).
  EXPECT_FLOAT_EQ([OWLInputTranslator flipY:0.0f viewHeight:600.0], 600.0f);
}

TEST(OWLInputTranslatorTest, FlipYTop) {
  // y=viewHeight (top in macOS) → 0 (top in Chromium).
  EXPECT_FLOAT_EQ([OWLInputTranslator flipY:600.0f viewHeight:600.0], 0.0f);
}

TEST(OWLInputTranslatorTest, FlipYFractional) {
  EXPECT_FLOAT_EQ([OWLInputTranslator flipY:300.5f viewHeight:600.0], 299.5f);
}

TEST(OWLInputTranslatorTest, FlipYZeroHeight) {
  // Edge case: zero-height view.
  EXPECT_FLOAT_EQ([OWLInputTranslator flipY:0.0f viewHeight:0.0], 0.0f);
}

TEST(OWLInputTranslatorTest, FlipYNegative) {
  // Negative y (mouse outside view bottom).
  EXPECT_FLOAT_EQ([OWLInputTranslator flipY:-10.0f viewHeight:600.0], 610.0f);
}

// --- Modifier mapping: NSEventModifierFlags → OWL ---

TEST(OWLInputTranslatorTest, ModifiersNone) {
  uint32_t mods = [OWLInputTranslator modifiersFromNSEventFlags:0
                                                        nsEvent:nil
                                                 pressedButtons:0];
  EXPECT_EQ(mods, 0u);
}

TEST(OWLInputTranslatorTest, ModifiersShift) {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:NSEventModifierFlagShift
                        nsEvent:nil
                 pressedButtons:0];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierShift);
}

TEST(OWLInputTranslatorTest, ModifiersCommand) {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:NSEventModifierFlagCommand
                        nsEvent:nil
                 pressedButtons:0];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierMeta);
}

TEST(OWLInputTranslatorTest, ModifiersOption) {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:NSEventModifierFlagOption
                        nsEvent:nil
                 pressedButtons:0];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierAlt);
}

TEST(OWLInputTranslatorTest, ModifiersControl) {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:NSEventModifierFlagControl
                        nsEvent:nil
                 pressedButtons:0];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierControl);
}

TEST(OWLInputTranslatorTest, ModifiersCapsLock) {
  uint32_t mods = [OWLInputTranslator
      modifiersFromNSEventFlags:NSEventModifierFlagCapsLock
                        nsEvent:nil
                 pressedButtons:0];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierCapsLock);
}

TEST(OWLInputTranslatorTest, ModifiersCombined) {
  NSEventModifierFlags flags =
      NSEventModifierFlagShift | NSEventModifierFlagCommand;
  uint32_t mods = [OWLInputTranslator modifiersFromNSEventFlags:flags
                                                        nsEvent:nil
                                                 pressedButtons:0];
  EXPECT_EQ(mods, (uint32_t)(kOWLModifierShift | kOWLModifierMeta));
}

// --- Mouse button modifiers (injected) ---

TEST(OWLInputTranslatorTest, ModifiersLeftButton) {
  uint32_t mods = [OWLInputTranslator modifiersFromNSEventFlags:0
                                                        nsEvent:nil
                                                 pressedButtons:(1 << 0)];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierLeftButton);
}

TEST(OWLInputTranslatorTest, ModifiersRightButton) {
  uint32_t mods = [OWLInputTranslator modifiersFromNSEventFlags:0
                                                        nsEvent:nil
                                                 pressedButtons:(1 << 1)];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierRightButton);
}

TEST(OWLInputTranslatorTest, ModifiersMiddleButton) {
  uint32_t mods = [OWLInputTranslator modifiersFromNSEventFlags:0
                                                        nsEvent:nil
                                                 pressedButtons:(1 << 2)];
  EXPECT_EQ(mods, (uint32_t)kOWLModifierMiddleButton);
}

TEST(OWLInputTranslatorTest, ModifiersMultipleButtons) {
  uint32_t mods = [OWLInputTranslator modifiersFromNSEventFlags:0
                                                        nsEvent:nil
                                                 pressedButtons:((1<<0)|(1<<2))];
  EXPECT_TRUE(mods & kOWLModifierLeftButton);
  EXPECT_TRUE(mods & kOWLModifierMiddleButton);
  EXPECT_FALSE(mods & kOWLModifierRightButton);
}

// --- Reverse mapping: OWL → NSEventModifierFlags ---

TEST(OWLInputTranslatorTest, ReverseModifiersNone) {
  NSEventModifierFlags flags =
      [OWLInputTranslator nsModifierFlagsFromOWLModifiers:0];
  EXPECT_EQ(flags, 0u);
}

TEST(OWLInputTranslatorTest, ReverseModifiersShiftMeta) {
  uint32_t mods = kOWLModifierShift | kOWLModifierMeta;
  NSEventModifierFlags flags =
      [OWLInputTranslator nsModifierFlagsFromOWLModifiers:mods];
  EXPECT_TRUE(flags & NSEventModifierFlagShift);
  EXPECT_TRUE(flags & NSEventModifierFlagCommand);
  EXPECT_FALSE(flags & NSEventModifierFlagOption);
}

TEST(OWLInputTranslatorTest, ReverseModifiersCapsLock) {
  uint32_t mods = kOWLModifierCapsLock;
  NSEventModifierFlags flags =
      [OWLInputTranslator nsModifierFlagsFromOWLModifiers:mods];
  EXPECT_TRUE(flags & NSEventModifierFlagCapsLock);
}

// Reverse mapping correctly drops mouse button and auto-repeat bits.
TEST(OWLInputTranslatorTest, ReverseModifiersDropsMouseButtons) {
  uint32_t mods = kOWLModifierShift | kOWLModifierLeftButton |
                  kOWLModifierRightButton | kOWLModifierIsAutoRepeat;
  NSEventModifierFlags flags =
      [OWLInputTranslator nsModifierFlagsFromOWLModifiers:mods];
  // Only Shift should be mapped; mouse/repeat bits silently dropped.
  EXPECT_TRUE(flags & NSEventModifierFlagShift);
  EXPECT_EQ(flags & ~NSEventModifierFlagShift, 0u);
}

// All OWL bits set → only keyboard modifiers mapped.
TEST(OWLInputTranslatorTest, ReverseModifiersAllBitsSet) {
  uint32_t mods = 0x1FF;  // All defined bits.
  NSEventModifierFlags flags =
      [OWLInputTranslator nsModifierFlagsFromOWLModifiers:mods];
  EXPECT_TRUE(flags & NSEventModifierFlagShift);
  EXPECT_TRUE(flags & NSEventModifierFlagControl);
  EXPECT_TRUE(flags & NSEventModifierFlagOption);
  EXPECT_TRUE(flags & NSEventModifierFlagCommand);
  EXPECT_TRUE(flags & NSEventModifierFlagCapsLock);
}

// --- flipY boundary: NaN ---

TEST(OWLInputTranslatorTest, FlipYNaN) {
  float result = [OWLInputTranslator flipY:NAN viewHeight:600.0];
  EXPECT_TRUE(std::isnan(result));
}

TEST(OWLInputTranslatorTest, FlipYInfinity) {
  float result = [OWLInputTranslator flipY:INFINITY viewHeight:600.0];
  EXPECT_EQ(result, -INFINITY);
}

}  // namespace
}  // namespace owl
