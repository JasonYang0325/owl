// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_TYPES_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_TYPES_H_

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Navigation result from WebViewHost.Navigate().
__attribute__((visibility("default")))
@interface OWLNavigationResult : NSObject
@property(nonatomic, readonly) BOOL success;
@property(nonatomic, readonly) int32_t httpStatusCode;
@property(nonatomic, readonly, nullable) NSString* errorDescription;
+ (instancetype)resultWithSuccess:(BOOL)success
                   httpStatusCode:(int32_t)code
                 errorDescription:(nullable NSString*)error;
@end

/// Page info from WebViewHost.GetPageInfo().
__attribute__((visibility("default")))
@interface OWLPageInfo : NSObject
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly) NSString* url;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
+ (instancetype)infoWithTitle:(NSString*)title
                          url:(NSString*)url
                    isLoading:(BOOL)isLoading
                    canGoBack:(BOOL)canGoBack
                   canGoForward:(BOOL)canGoForward;
@end

/// Render surface info from OnRenderSurfaceChanged.
__attribute__((visibility("default")))
@interface OWLRenderSurface : NSObject
@property(nonatomic, readonly) uint32_t caContextId;
@property(nonatomic, readonly) uint32_t ioSurfaceMachPort;  // 0 if N/A
@property(nonatomic, readonly) CGSize pixelSize;
@property(nonatomic, readonly) CGFloat scaleFactor;
+ (instancetype)surfaceWithContextId:(uint32_t)contextId
                    ioSurfaceMachPort:(uint32_t)machPort
                           pixelSize:(CGSize)size
                         scaleFactor:(CGFloat)scale;
@end

/// Unhandled key event from renderer (did not preventDefault).
__attribute__((visibility("default")))
@interface OWLKeyEvent : NSObject
@property(nonatomic, readonly) int32_t type;         // KeyEventType enum
@property(nonatomic, readonly) int32_t nativeKeyCode;
@property(nonatomic, readonly) uint32_t modifiers;
@property(nonatomic, readonly, nullable) NSString* characters;
+ (instancetype)eventWithType:(int32_t)type
                nativeKeyCode:(int32_t)nativeKeyCode
                    modifiers:(uint32_t)modifiers
                   characters:(nullable NSString*)characters;
@end

/// Validates that hostPath is safe to execute.
/// Must be inside app bundle and pass code signature check.
/// Returns nil if valid, or an NSError describing the failure.
NSError* _Nullable OWLValidateHostPath(NSString* hostPath);

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_TYPES_H_
