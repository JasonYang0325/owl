// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_CLIENT_OWL_AI_CHAT_SESSION_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_AI_CHAT_SESSION_H_
#import <Foundation/Foundation.h>
#import "third_party/owl/client/OWLAIMessage.h"
NS_ASSUME_NONNULL_BEGIN
__attribute__((visibility("default")))
@interface OWLAIChatSession : NSObject
@property(nonatomic, readonly, copy) NSArray<OWLAIMessage*>* messages;
@property(nonatomic, copy, nullable) NSString* pageContext;
- (void)addMessage:(OWLAIMessage*)message;
- (void)clearHistory;
/// Format messages for AI API (role: content pairs).
- (NSString*)contextForAI;
@end
NS_ASSUME_NONNULL_END
#endif
