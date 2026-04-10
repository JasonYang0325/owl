// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAIChatSession.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

TEST(OWLAIMessageTest, CreatesWithRole) {
  OWLAIMessage* msg = [OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Hello"];
  EXPECT_EQ(msg.role, OWLAIRoleUser);
  EXPECT_TRUE([msg.content isEqualToString:@"Hello"]);
  EXPECT_NE(msg.timestamp, nil);
}

TEST(OWLAIMessageTest, AssistantRole) {
  OWLAIMessage* msg = [OWLAIMessage messageWithRole:OWLAIRoleAssistant content:@"Hi"];
  EXPECT_EQ(msg.role, OWLAIRoleAssistant);
}

TEST(OWLAIChatSessionTest, InitiallyEmpty) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  EXPECT_EQ(session.messages.count, 0u);
}

TEST(OWLAIChatSessionTest, AddMessage) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Q1"]];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleAssistant content:@"A1"]];
  EXPECT_EQ(session.messages.count, 2u);
}

TEST(OWLAIChatSessionTest, ClearHistory) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Q"]];
  [session clearHistory];
  EXPECT_EQ(session.messages.count, 0u);
}

TEST(OWLAIChatSessionTest, ContextForAI) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Hello"]];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleAssistant content:@"Hi"]];
  NSString* ctx = [session contextForAI];
  EXPECT_TRUE([ctx containsString:@"user: Hello"]);
  EXPECT_TRUE([ctx containsString:@"assistant: Hi"]);
}

TEST(OWLAIChatSessionTest, ContextWithPageContext) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  session.pageContext = @"This is a test page.";
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Summarize"]];
  NSString* ctx = [session contextForAI];
  EXPECT_TRUE([ctx containsString:@"[Page Context]"]);
  EXPECT_TRUE([ctx containsString:@"This is a test page."]);
  EXPECT_TRUE([ctx containsString:@"user: Summarize"]);
}

TEST(OWLAIChatSessionTest, ContextWithoutPageContext) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Hi"]];
  NSString* ctx = [session contextForAI];
  EXPECT_FALSE([ctx containsString:@"[Page Context]"]);
}

TEST(OWLAIChatSessionTest, MessagesReturnsCopy) {
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  [session addMessage:[OWLAIMessage messageWithRole:OWLAIRoleUser content:@"Q"]];
  NSArray* msgs = session.messages;
  [session clearHistory];
  EXPECT_EQ(msgs.count, 1u);  // Copy unaffected.
  EXPECT_EQ(session.messages.count, 0u);
}

// BH-015: Main-thread assertion in DEBUG mode.
// AC-3: Verify that calling from a background thread triggers an assertion.
#if !defined(NDEBUG)
TEST(OWLAIChatSessionTest, MainThreadAssertionOnAddMessage) {
  // In DEBUG builds, addMessage must assert when called off-main-thread.
  OWLAIChatSession* session = [[OWLAIChatSession alloc] init];
  OWLAIMessage* msg = [OWLAIMessage messageWithRole:OWLAIRoleUser
                                            content:@"test"];
  __block BOOL assertionFired = NO;
  // NSAssert raises NSInternalInconsistencyException.
  NSAssertionHandler* original = [NSAssertionHandler currentHandler];
  (void)original;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   @try {
                     [session addMessage:msg];
                   } @catch (NSException* e) {
                     if ([e.name
                             isEqualToString:
                                 NSInternalInconsistencyException]) {
                       assertionFired = YES;
                     }
                   }
                   dispatch_semaphore_signal(sem);
                 });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  EXPECT_TRUE(assertionFired);
}
#endif  // !defined(NDEBUG)

}  // namespace
}  // namespace owl
