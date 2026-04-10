// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_CLIENT_OWL_TAB_MANAGER_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_TAB_MANAGER_H_

#import <Foundation/Foundation.h>

#import "third_party/owl/bridge/OWLBridgeWebView.h"
#import "third_party/owl/client/OWLTab.h"

NS_ASSUME_NONNULL_BEGIN

@class OWLBridgeBrowserContext;
@class OWLWebContentView;
@class OWLTabManager;

@protocol OWLTabManagerDelegate <NSObject>
@optional
- (void)tabManager:(OWLTabManager*)manager didCreateTab:(OWLTab*)tab;
- (void)tabManager:(OWLTabManager*)manager didActivateTab:(OWLTab*)tab;
- (void)tabManager:(OWLTabManager*)manager didCloseTab:(OWLTab*)tab;
@end

__attribute__((visibility("default")))
@interface OWLTabManager : NSObject <OWLWebViewDelegate>

@property(nonatomic, readonly, copy) NSArray<OWLTab*>* tabs;
@property(nonatomic, readonly, nullable) OWLTab* activeTab;
@property(weak, nonatomic, nullable) id<OWLTabManagerDelegate> delegate;
@property(nonatomic, readonly) NSUInteger tabCount;

- (instancetype)initWithBrowserContext:(OWLBridgeBrowserContext*)context
                           contentView:(nullable OWLWebContentView*)contentView;
- (instancetype)init NS_UNAVAILABLE;

- (void)createTabWithURL:(nullable NSURL*)url
              completion:(void (^)(OWLTab* _Nullable,
                                   NSError* _Nullable))completion;
- (void)closeTab:(NSUUID*)tabId completion:(void (^)(void))completion;
- (void)activateTab:(NSUUID*)tabId;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_CLIENT_OWL_TAB_MANAGER_H_
