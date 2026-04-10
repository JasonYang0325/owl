// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/client/OWLTabManager.h"

#import "third_party/owl/bridge/OWLBridgeBrowserContext.h"
#import "third_party/owl/client/OWLWebContentView.h"

@implementation OWLTabManager {
  OWLBridgeBrowserContext* _context;
  OWLWebContentView* _contentView;
  NSMutableArray<OWLTab*>* _tabs;
  OWLTab* _activeTab;
}

@synthesize delegate = _delegate;

- (instancetype)initWithBrowserContext:(OWLBridgeBrowserContext*)context
                           contentView:(nullable OWLWebContentView*)contentView {
  self = [super init];
  if (self) {
    _context = context;
    _contentView = contentView;
    _tabs = [NSMutableArray array];
  }
  return self;
}

- (NSArray<OWLTab*>*)tabs {
  return [_tabs copy];
}

- (OWLTab*)activeTab {
  return _activeTab;
}

- (NSUInteger)tabCount {
  return _tabs.count;
}

- (void)createTabWithURL:(nullable NSURL*)url
              completion:(void (^)(OWLTab*, NSError*))completion {
  [_context createWebViewWithDelegate:self
                           completion:^(OWLBridgeWebView* webView,
                                        NSError* error) {
    if (!webView) {
      completion(nil, error);
      return;
    }

    OWLTab* tab = [[OWLTab alloc] initWithWebView:webView];
    [self->_tabs addObject:tab];

    // Auto-activate if first tab.
    if (self->_tabs.count == 1) {
      [self activateTab:tab.tabId];
    }

    if ([self->_delegate respondsToSelector:
            @selector(tabManager:didCreateTab:)]) {
      [self->_delegate tabManager:self didCreateTab:tab];
    }

    // Navigate if URL provided.
    if (url) {
      [webView navigateToURL:url completion:^(OWLNavigationResult* r) {}];
    }

    completion(tab, nil);
  }];
}

- (void)closeTab:(NSUUID*)tabId completion:(void (^)(void))completion {
  OWLTab* tab = [self tabForId:tabId];
  if (!tab || tab.isClosing) {
    completion();
    return;
  }

  tab.isClosing = YES;

  // Synchronous state update.
  NSUInteger index = [_tabs indexOfObject:tab];
  BOOL wasActive = (tab == _activeTab);
  [_tabs removeObject:tab];

  if ([_delegate respondsToSelector:@selector(tabManager:didCloseTab:)]) {
    [_delegate tabManager:self didCloseTab:tab];
  }

  if (wasActive) {
    if (_tabs.count > 0) {
      NSUInteger newIndex = MIN(index, _tabs.count - 1);
      [self activateTab:_tabs[newIndex].tabId];
    } else {
      _activeTab = nil;
      [_contentView clearRenderSurface];
    }
  }

  // Async cleanup.
  [tab.webView closeWithCompletion:^{
    completion();
  }];
}

- (void)activateTab:(NSUUID*)tabId {
  OWLTab* newTab = [self tabForId:tabId];
  if (!newTab || newTab == _activeTab || newTab.isClosing) return;

  OWLTab* oldTab = _activeTab;
  _activeTab = newTab;

  [newTab.webView setVisible:YES completion:^{}];
  if (oldTab) {
    [oldTab.webView setVisible:NO completion:^{}];
  }

  if ([_delegate respondsToSelector:@selector(tabManager:didActivateTab:)]) {
    [_delegate tabManager:self didActivateTab:newTab];
  }
}

// MARK: - OWLWebViewDelegate

- (void)webView:(OWLBridgeWebView*)webView
    didUpdatePageInfo:(OWLPageInfo*)info {
  OWLTab* tab = [self tabForWebView:webView];
  if (tab && !tab.isClosing) {
    tab.title = info.title;
    tab.url = info.url;
    tab.isLoading = info.isLoading;
  }
}

- (void)webView:(OWLBridgeWebView*)webView
    didFinishLoadWithSuccess:(BOOL)success {
  // Could forward to delegate if needed.
}

- (void)webView:(OWLBridgeWebView*)webView
    didUpdateRenderSurface:(OWLRenderSurface*)surface {
  OWLTab* tab = [self tabForWebView:webView];
  if (tab == _activeTab && !tab.isClosing) {
    [_contentView updateRenderSurfaceWithContextId:surface.caContextId
                                         pixelSize:surface.pixelSize
                                       scaleFactor:surface.scaleFactor];
  }
}

// MARK: - Helpers

- (nullable OWLTab*)tabForId:(NSUUID*)tabId {
  for (OWLTab* tab in _tabs) {
    if ([tab.tabId isEqual:tabId]) return tab;
  }
  return nil;
}

- (nullable OWLTab*)tabForWebView:(OWLBridgeWebView*)webView {
  for (OWLTab* tab in _tabs) {
    if (tab.webView == webView) return tab;
  }
  return nil;
}

@end
