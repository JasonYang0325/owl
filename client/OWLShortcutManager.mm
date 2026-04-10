// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLShortcutManager.h"
#import <Carbon/Carbon.h>

@implementation OWLShortcutManager
+ (OWLBrowserAction)actionForKeyCode:(uint16_t)keyCode
                           modifiers:(uint32_t)modifiers {
  BOOL cmd = (modifiers & kOWLModifierMeta) != 0;
  BOOL shift = (modifiers & kOWLModifierShift) != 0;
  if (!cmd) return OWLBrowserActionNone;

  if (cmd && shift) {
    switch (keyCode) {
      case kVK_ANSI_RightBracket: return OWLBrowserActionNextTab;
      case kVK_ANSI_LeftBracket:  return OWLBrowserActionPrevTab;
      default: break;
    }
  }

  switch (keyCode) {
    case kVK_ANSI_T: return OWLBrowserActionNewTab;
    case kVK_ANSI_W: return OWLBrowserActionCloseTab;
    case kVK_ANSI_L: return OWLBrowserActionFocusAddressBar;
    case kVK_ANSI_R: return OWLBrowserActionReload;
    case kVK_ANSI_LeftBracket:  return OWLBrowserActionGoBack;
    case kVK_ANSI_RightBracket: return OWLBrowserActionGoForward;
    case kVK_ANSI_Period:  return OWLBrowserActionStop;
    default: return OWLBrowserActionNone;
  }
}
@end
