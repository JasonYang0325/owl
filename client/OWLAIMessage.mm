// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAIMessage.h"
@implementation OWLAIMessage
@synthesize role = _role;
@synthesize content = _content;
@synthesize timestamp = _timestamp;
+ (instancetype)messageWithRole:(OWLAIRole)role content:(NSString*)content {
  OWLAIMessage* msg = [[OWLAIMessage alloc] init];
  msg->_role = role;
  msg->_content = [content copy];
  msg->_timestamp = [NSDate date];
  return msg;
}
@end
