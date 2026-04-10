// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLShortcutManager.h"
#import <Carbon/Carbon.h>
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

TEST(OWLShortcutManagerTest, CmdT_NewTab) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_T
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionNewTab);
}

TEST(OWLShortcutManagerTest, CmdW_CloseTab) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_W
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionCloseTab);
}

TEST(OWLShortcutManagerTest, CmdL_FocusAddressBar) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_L
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionFocusAddressBar);
}

TEST(OWLShortcutManagerTest, CmdR_Reload) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_R
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionReload);
}

TEST(OWLShortcutManagerTest, CmdLeftBracket_GoBack) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_LeftBracket
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionGoBack);
}

TEST(OWLShortcutManagerTest, CmdRightBracket_GoForward) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_RightBracket
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionGoForward);
}

TEST(OWLShortcutManagerTest, CmdPeriod_Stop) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_Period
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionStop);
}

TEST(OWLShortcutManagerTest, CmdShiftRightBracket_NextTab) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_RightBracket
                                       modifiers:(kOWLModifierMeta | kOWLModifierShift)],
            OWLBrowserActionNextTab);
}

TEST(OWLShortcutManagerTest, CmdShiftLeftBracket_PrevTab) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_LeftBracket
                                       modifiers:(kOWLModifierMeta | kOWLModifierShift)],
            OWLBrowserActionPrevTab);
}

TEST(OWLShortcutManagerTest, NoCmdModifier_ReturnsNone) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_T
                                       modifiers:0],
            OWLBrowserActionNone);
}

TEST(OWLShortcutManagerTest, UnknownKey_ReturnsNone) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_Z
                                       modifiers:kOWLModifierMeta],
            OWLBrowserActionNone);
}

TEST(OWLShortcutManagerTest, OnlyShift_ReturnsNone) {
  EXPECT_EQ([OWLShortcutManager actionForKeyCode:kVK_ANSI_T
                                       modifiers:kOWLModifierShift],
            OWLBrowserActionNone);
}

}  // namespace
}  // namespace owl
