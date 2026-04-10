// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAgentSession.h"
#include "testing/gtest/include/gtest/gtest.h"
namespace owl { namespace {

TEST(OWLAgentTaskTest, CreateTask) {
  OWLAgentTask* t = [OWLAgentTask taskWithDescription:@"Book hotel"];
  EXPECT_TRUE(t.taskId.length > 0);
  EXPECT_TRUE([t.taskDescription isEqualToString:@"Book hotel"]);
  EXPECT_EQ(t.status, OWLAgentTaskStatusPending);
}

TEST(OWLAgentTaskTest, UpdateStatus) {
  OWLAgentTask* t = [OWLAgentTask taskWithDescription:@"Test"];
  t.status = OWLAgentTaskStatusRunning;
  EXPECT_EQ(t.status, OWLAgentTaskStatusRunning);
  t.status = OWLAgentTaskStatusCompleted;
  t.result = @"Done";
  EXPECT_EQ(t.status, OWLAgentTaskStatusCompleted);
  EXPECT_TRUE([t.result isEqualToString:@"Done"]);
}

TEST(OWLAgentSessionTest, Ephemeral) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  EXPECT_TRUE(s.isEphemeral);
  EXPECT_TRUE(s.sessionId.length > 0);
  EXPECT_FALSE(s.isDestroyed);
}

TEST(OWLAgentSessionTest, AddAndFindTask) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  OWLAgentTask* t = [OWLAgentTask taskWithDescription:@"Search"];
  [s addTask:t];
  EXPECT_EQ(s.tasks.count, 1u);
  EXPECT_EQ([s taskForId:t.taskId], t);
  EXPECT_EQ([s taskForId:@"nonexistent"], nil);
}

TEST(OWLAgentSessionTest, DestroyClears) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  [s addTask:[OWLAgentTask taskWithDescription:@"A"]];
  [s destroy];
  EXPECT_TRUE(s.isDestroyed);
  EXPECT_EQ(s.tasks.count, 0u);
}

TEST(OWLAgentSessionTest, AddAfterDestroyIsNoOp) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  [s destroy];
  [s addTask:[OWLAgentTask taskWithDescription:@"Should not add"]];
  EXPECT_EQ(s.tasks.count, 0u);
}

// BH-028: AgentTask state machine — full lifecycle.
// AC-7: Pending → Running → NeedsConfirmation → Running → Completed.
TEST(OWLAgentSessionTest, FullTaskLifecycle) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  OWLAgentTask* t = [OWLAgentTask taskWithDescription:@"Multi-step op"];
  [s addTask:t];

  // Initial state: Pending.
  EXPECT_EQ(t.status, OWLAgentTaskStatusPending);

  // Pending → Running via startTask.
  [s startTask:t.taskId];
  EXPECT_EQ(t.status, OWLAgentTaskStatusRunning);

  // Running → NeedsConfirmation (simulate agent asking for user approval).
  t.status = OWLAgentTaskStatusNeedsConfirmation;
  EXPECT_EQ(t.status, OWLAgentTaskStatusNeedsConfirmation);

  // NeedsConfirmation → Running via resumeTask.
  [s resumeTask:t.taskId];
  EXPECT_EQ(t.status, OWLAgentTaskStatusRunning);

  // Running → Completed.
  t.status = OWLAgentTaskStatusCompleted;
  t.result = @"All done";
  EXPECT_EQ(t.status, OWLAgentTaskStatusCompleted);
  EXPECT_TRUE([t.result isEqualToString:@"All done"]);
}

// AC-8: startTask on non-Pending status is a no-op.
TEST(OWLAgentSessionTest, StartTaskOnlyFromPending) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  OWLAgentTask* t = [OWLAgentTask taskWithDescription:@"Guard test"];
  [s addTask:t];

  // Move to Running first.
  [s startTask:t.taskId];
  EXPECT_EQ(t.status, OWLAgentTaskStatusRunning);

  // Calling startTask again should be a no-op (already Running).
  [s startTask:t.taskId];
  EXPECT_EQ(t.status, OWLAgentTaskStatusRunning);

  // Move to Completed, then try startTask — should remain Completed.
  t.status = OWLAgentTaskStatusCompleted;
  [s startTask:t.taskId];
  EXPECT_EQ(t.status, OWLAgentTaskStatusCompleted);

  // Also verify for Failed status.
  OWLAgentTask* t2 = [OWLAgentTask taskWithDescription:@"Will fail"];
  [s addTask:t2];
  t2.status = OWLAgentTaskStatusFailed;
  [s startTask:t2.taskId];
  EXPECT_EQ(t2.status, OWLAgentTaskStatusFailed);
}

// startTask on a destroyed session is a no-op.
TEST(OWLAgentSessionTest, StartTaskAfterDestroyIsNoOp) {
  OWLAgentSession* s = [[OWLAgentSession alloc] initEphemeral];
  OWLAgentTask* t = [OWLAgentTask taskWithDescription:@"Doomed"];
  [s addTask:t];
  [s destroy];
  // Task list is cleared by destroy, but even with a direct reference,
  // the session should not crash.
  [s startTask:t.taskId];
  EXPECT_TRUE(s.isDestroyed);
}

} }
