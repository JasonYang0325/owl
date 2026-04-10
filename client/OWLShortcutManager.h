// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_CLIENT_OWL_SHORTCUT_MANAGER_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_SHORTCUT_MANAGER_H_
#import <Foundation/Foundation.h>
#import "third_party/owl/client/OWLInputTranslator.h"

typedef NS_ENUM(NSInteger, OWLBrowserAction) {
  OWLBrowserActionNone = -1,
  OWLBrowserActionNewTab,
  OWLBrowserActionCloseTab,
  OWLBrowserActionNextTab,
  OWLBrowserActionPrevTab,
  OWLBrowserActionFocusAddressBar,
  OWLBrowserActionReload,
  OWLBrowserActionGoBack,
  OWLBrowserActionGoForward,
  OWLBrowserActionStop,
};

__attribute__((visibility("default")))
@interface OWLShortcutManager : NSObject
+ (OWLBrowserAction)actionForKeyCode:(uint16_t)keyCode
                           modifiers:(uint32_t)modifiers;
@end
#endif
