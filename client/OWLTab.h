// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_CLIENT_OWL_TAB_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_TAB_H_

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OWLBridgeWebView;

__attribute__((visibility("default")))
@interface OWLTab : NSObject

@property(nonatomic, readonly) NSUUID* tabId;
@property(nonatomic, readonly) OWLBridgeWebView* webView;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy, nullable) NSString* url;
@property(nonatomic) BOOL isLoading;
@property(nonatomic) BOOL isClosing;

- (instancetype)initWithWebView:(OWLBridgeWebView*)webView;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_CLIENT_OWL_TAB_H_
