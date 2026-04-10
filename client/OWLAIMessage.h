// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_CLIENT_OWL_AI_MESSAGE_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_AI_MESSAGE_H_
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, OWLAIRole) {
  OWLAIRoleUser,
  OWLAIRoleAssistant,
  OWLAIRoleSystem,
};
__attribute__((visibility("default")))
@interface OWLAIMessage : NSObject
@property(nonatomic, readonly) OWLAIRole role;
@property(nonatomic, readonly, copy) NSString* content;
@property(nonatomic, readonly) NSDate* timestamp;
+ (instancetype)messageWithRole:(OWLAIRole)role content:(NSString*)content;
@end
NS_ASSUME_NONNULL_END
#endif
