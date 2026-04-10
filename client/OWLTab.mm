// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/client/OWLTab.h"

@implementation OWLTab

@synthesize tabId = _tabId;
@synthesize webView = _webView;
@synthesize title = _title;
@synthesize url = _url;
@synthesize isLoading = _isLoading;
@synthesize isClosing = _isClosing;

- (instancetype)initWithWebView:(OWLBridgeWebView*)webView {
  self = [super init];
  if (self) {
    _tabId = [NSUUID UUID];
    _webView = webView;
    _title = @"";
    _isClosing = NO;
  }
  return self;
}

@end
