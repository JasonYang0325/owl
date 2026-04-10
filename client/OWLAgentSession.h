// Copyright 2026 AntlerAI. All rights reserved.
// Phase 8: Agent Mode — ephemeral session + task runner.
#ifndef THIRD_PARTY_OWL_CLIENT_OWL_AGENT_SESSION_H_
#define THIRD_PARTY_OWL_CLIENT_OWL_AGENT_SESSION_H_
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OWLAgentTaskStatus) {
  OWLAgentTaskStatusPending,
  OWLAgentTaskStatusRunning,
  OWLAgentTaskStatusCompleted,
  OWLAgentTaskStatusFailed,
  OWLAgentTaskStatusNeedsConfirmation,
};

__attribute__((visibility("default")))
@interface OWLAgentTask : NSObject
@property(nonatomic, readonly, copy) NSString* taskId;
@property(nonatomic, readonly, copy) NSString* taskDescription;
@property(nonatomic) OWLAgentTaskStatus status;
@property(nonatomic, copy, nullable) NSString* result;
+ (instancetype)taskWithDescription:(NSString*)desc;
@end

@class OWLAgentSession;

@protocol OWLAgentSessionDelegate <NSObject>
@optional
- (void)agentSession:(OWLAgentSession*)session
    taskDidChangeStatus:(OWLAgentTask*)task;
@end

__attribute__((visibility("default")))
@interface OWLAgentSession : NSObject
@property(nonatomic, readonly, copy) NSString* sessionId;
@property(nonatomic, readonly) BOOL isEphemeral;
@property(nonatomic, readonly, copy) NSArray<OWLAgentTask*>* tasks;
@property(weak, nonatomic, nullable) id<OWLAgentSessionDelegate> delegate;
- (instancetype)initEphemeral;
- (void)addTask:(OWLAgentTask*)task;
- (nullable OWLAgentTask*)taskForId:(NSString*)taskId;
/// BH-028: Transition a task from Pending to Running.
- (void)startTask:(NSString*)taskId;
- (void)resumeTask:(NSString*)taskId;
- (void)cancelTask:(NSString*)taskId;
- (void)destroy;
@property(nonatomic, readonly) BOOL isDestroyed;
@end

NS_ASSUME_NONNULL_END
#endif
