// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLBridgeTypes.h"

#include <sys/stat.h>

@implementation OWLNavigationResult {
  BOOL _success;
  int32_t _httpStatusCode;
  NSString* _errorDescription;
}

+ (instancetype)resultWithSuccess:(BOOL)success
                   httpStatusCode:(int32_t)code
                 errorDescription:(nullable NSString*)error {
  OWLNavigationResult* result = [[OWLNavigationResult alloc] init];
  result->_success = success;
  result->_httpStatusCode = code;
  result->_errorDescription = [error copy];
  return result;
}

- (BOOL)success { return _success; }
- (int32_t)httpStatusCode { return _httpStatusCode; }
- (NSString*)errorDescription { return _errorDescription; }

@end

@implementation OWLPageInfo {
  NSString* _title;
  NSString* _url;
  BOOL _isLoading;
  BOOL _canGoBack;
  BOOL _canGoForward;
}

+ (instancetype)infoWithTitle:(NSString*)title
                          url:(NSString*)url
                    isLoading:(BOOL)isLoading
                    canGoBack:(BOOL)canGoBack
                   canGoForward:(BOOL)canGoForward {
  OWLPageInfo* info = [[OWLPageInfo alloc] init];
  info->_title = [title copy];
  info->_url = [url copy];
  info->_isLoading = isLoading;
  info->_canGoBack = canGoBack;
  info->_canGoForward = canGoForward;
  return info;
}

- (NSString*)title { return _title; }
- (NSString*)url { return _url; }
- (BOOL)isLoading { return _isLoading; }
- (BOOL)canGoBack { return _canGoBack; }
- (BOOL)canGoForward { return _canGoForward; }

@end

@implementation OWLRenderSurface {
  uint32_t _caContextId;
  uint32_t _ioSurfaceMachPort;
  CGSize _pixelSize;
  CGFloat _scaleFactor;
}

+ (instancetype)surfaceWithContextId:(uint32_t)contextId
                    ioSurfaceMachPort:(uint32_t)machPort
                           pixelSize:(CGSize)size
                         scaleFactor:(CGFloat)scale {
  OWLRenderSurface* surface = [[OWLRenderSurface alloc] init];
  surface->_caContextId = contextId;
  surface->_ioSurfaceMachPort = machPort;
  surface->_pixelSize = size;
  surface->_scaleFactor = scale;
  return surface;
}

- (uint32_t)caContextId { return _caContextId; }
- (uint32_t)ioSurfaceMachPort { return _ioSurfaceMachPort; }
- (CGSize)pixelSize { return _pixelSize; }
- (CGFloat)scaleFactor { return _scaleFactor; }

@end

@implementation OWLKeyEvent {
  int32_t _type;
  int32_t _nativeKeyCode;
  uint32_t _modifiers;
  NSString* _characters;
}

+ (instancetype)eventWithType:(int32_t)type
                nativeKeyCode:(int32_t)nativeKeyCode
                    modifiers:(uint32_t)modifiers
                   characters:(nullable NSString*)characters {
  OWLKeyEvent* event = [[OWLKeyEvent alloc] init];
  event->_type = type;
  event->_nativeKeyCode = nativeKeyCode;
  event->_modifiers = modifiers;
  event->_characters = [characters copy];
  return event;
}

- (int32_t)type { return _type; }
- (int32_t)nativeKeyCode { return _nativeKeyCode; }
- (uint32_t)modifiers { return _modifiers; }
- (NSString*)characters { return _characters; }

@end

NSError* _Nullable OWLValidateHostPath(NSString* hostPath) {
  if (hostPath.length == 0) {
    return [NSError errorWithDomain:@"OWLBridge"
                              code:1
                          userInfo:@{NSLocalizedDescriptionKey:
                                         @"Host path is empty"}];
  }

  // Resolve symlinks and normalize path.
  const char* cpath = [hostPath fileSystemRepresentation];
  char resolved[PATH_MAX];
  if (realpath(cpath, resolved) == NULL) {
    return [NSError errorWithDomain:@"OWLBridge"
                              code:2
                          userInfo:@{NSLocalizedDescriptionKey:
                              [NSString stringWithFormat:
                                  @"Cannot resolve path: %@", hostPath]}];
  }
  NSString* normalizedPath =
      [[NSFileManager defaultManager]
          stringWithFileSystemRepresentation:resolved
                                     length:strlen(resolved)];

  // Verify the file exists and is executable.
  struct stat st;
  if (stat(resolved, &st) != 0 || !(st.st_mode & S_IXUSR)) {
    return [NSError errorWithDomain:@"OWLBridge"
                              code:3
                          userInfo:@{NSLocalizedDescriptionKey:
                              [NSString stringWithFormat:
                                  @"Not an executable file: %@",
                                  normalizedPath]}];
  }

  // Verify path is inside the app bundle.
  // Append "/" to prevent sibling-prefix bypass (e.g., App.app.evil/).
  NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
  NSString* bundlePrefix = [bundlePath hasSuffix:@"/"]
      ? bundlePath
      : [bundlePath stringByAppendingString:@"/"];
  if (![normalizedPath hasPrefix:bundlePrefix] &&
      ![normalizedPath isEqualToString:bundlePath]) {
    return [NSError errorWithDomain:@"OWLBridge"
                              code:4
                          userInfo:@{NSLocalizedDescriptionKey:
                              [NSString stringWithFormat:
                                  @"Host path is not inside app bundle. "
                                  @"Path: %@, Bundle: %@",
                                  normalizedPath, bundlePath]}];
  }

  return nil;  // Valid.
}
