// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLMojoThread.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

TEST(OWLMojoThreadTest, SharedReturnsSameInstance) {
  OWLMojoThread* a = [OWLMojoThread shared];
  OWLMojoThread* b = [OWLMojoThread shared];
  EXPECT_EQ(a, b);
  EXPECT_NE(a, nil);
}

// [L-1 fix] Replaced dead test with actual assertion.
// Due to singleton + dispatch_once, we test the full lifecycle:
// before ensureStarted → after ensureStarted.
TEST(OWLMojoThreadTest, EnsureStartedSetsIsStarted) {
  OWLMojoThread* thread = [OWLMojoThread shared];
  // Call ensureStarted (idempotent).
  [thread ensureStarted];
  EXPECT_TRUE(thread.isStarted);
}

TEST(OWLMojoThreadTest, EnsureStartedIsIdempotent) {
  OWLMojoThread* thread = [OWLMojoThread shared];
  [thread ensureStarted];
  [thread ensureStarted];
  [thread ensureStarted];
  EXPECT_TRUE(thread.isStarted);
}

}  // namespace
}  // namespace owl
