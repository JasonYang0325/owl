// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_CLIENT_OWL_ADDRESS_BAR_CONTROLLER_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_ADDRESS_BAR_CONTROLLER_H_
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
__attribute__((visibility("default")))
@interface OWLAddressBarController : NSObject
+ (nullable NSURL*)urlFromInput:(NSString*)input;
+ (BOOL)inputLooksLikeURL:(NSString*)input;
@end
NS_ASSUME_NONNULL_END
#endif
