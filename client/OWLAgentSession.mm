// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAgentSession.h"
@implementation OWLAgentTask
@synthesize taskId = _taskId, taskDescription = _taskDescription;
@synthesize status = _status, result = _result;
+ (instancetype)taskWithDescription:(NSString*)desc {
  OWLAgentTask* t = [[OWLAgentTask alloc] init];
  t->_taskId = [[NSUUID UUID] UUIDString];
  t->_taskDescription = [desc copy];
  t->_status = OWLAgentTaskStatusPending;
  return t;
}
@end

@implementation OWLAgentSession {
  NSMutableArray<OWLAgentTask*>* _tasks;
  BOOL _destroyed;
}
@synthesize sessionId = _sessionId, isEphemeral = _isEphemeral, delegate = _delegate;
- (instancetype)initEphemeral {
  self = [super init];
  if (self) {
    _sessionId = [[NSUUID UUID] UUIDString];
    _isEphemeral = YES;
    _tasks = [NSMutableArray array];
    _destroyed = NO;
  }
  return self;
}
- (NSArray<OWLAgentTask*>*)tasks { return [_tasks copy]; }
- (void)addTask:(OWLAgentTask*)task {
  if (!_destroyed && task) [_tasks addObject:task];
}
- (nullable OWLAgentTask*)taskForId:(NSString*)taskId {
  for (OWLAgentTask* t in _tasks) {
    if ([t.taskId isEqualToString:taskId]) return t;
  }
  return nil;
}
// BH-028: Transition Pending → Running.
- (void)startTask:(NSString*)taskId {
  if (_destroyed) return;
  OWLAgentTask* task = [self taskForId:taskId];
  if (task && task.status == OWLAgentTaskStatusPending) {
    task.status = OWLAgentTaskStatusRunning;
    if ([_delegate respondsToSelector:@selector(agentSession:taskDidChangeStatus:)]) {
      [_delegate agentSession:self taskDidChangeStatus:task];
    }
  }
}
- (void)resumeTask:(NSString*)taskId {
  OWLAgentTask* task = [self taskForId:taskId];
  if (task && task.status == OWLAgentTaskStatusNeedsConfirmation) {
    task.status = OWLAgentTaskStatusRunning;
    if ([_delegate respondsToSelector:@selector(agentSession:taskDidChangeStatus:)]) {
      [_delegate agentSession:self taskDidChangeStatus:task];
    }
  }
}
- (void)cancelTask:(NSString*)taskId {
  OWLAgentTask* task = [self taskForId:taskId];
  if (task && (task.status == OWLAgentTaskStatusNeedsConfirmation ||
               task.status == OWLAgentTaskStatusRunning)) {
    task.status = OWLAgentTaskStatusFailed;
    if ([_delegate respondsToSelector:@selector(agentSession:taskDidChangeStatus:)]) {
      [_delegate agentSession:self taskDidChangeStatus:task];
    }
  }
}
- (void)destroy { _destroyed = YES; [_tasks removeAllObjects]; }
- (BOOL)isDestroyed { return _destroyed; }
@end
