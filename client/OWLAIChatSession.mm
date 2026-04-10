// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAIChatSession.h"
@implementation OWLAIChatSession {
  NSMutableArray<OWLAIMessage*>* _messages;
}
@synthesize pageContext = _pageContext;

- (instancetype)init {
  self = [super init];
  if (self) { _messages = [NSMutableArray array]; }
  return self;
}

- (NSArray<OWLAIMessage*>*)messages { return [_messages copy]; }

// BH-015: Main-thread assertions for collection mutation.
- (void)addMessage:(OWLAIMessage*)message {
  NSAssert([NSThread isMainThread], @"Must be called on main thread");
  if (message) [_messages addObject:message];
}

- (void)clearHistory {
  NSAssert([NSThread isMainThread], @"Must be called on main thread");
  [_messages removeAllObjects];
}

- (NSString*)contextForAI {
  NSMutableString* ctx = [NSMutableString string];
  if (_pageContext.length > 0) {
    [ctx appendFormat:@"[Page Context]\n%@\n\n", _pageContext];
  }
  for (OWLAIMessage* msg in _messages) {
    NSString* role = @"unknown";
    switch (msg.role) {
      case OWLAIRoleUser: role = @"user"; break;
      case OWLAIRoleAssistant: role = @"assistant"; break;
      case OWLAIRoleSystem: role = @"system"; break;
    }
    [ctx appendFormat:@"%@: %@\n", role, msg.content];
  }
  return [ctx copy];
}
@end
