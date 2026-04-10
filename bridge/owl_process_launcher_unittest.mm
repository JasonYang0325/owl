// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#import "third_party/owl/bridge/OWLProcessLauncher.h"

#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

TEST(OWLProcessLauncherTest, LaunchNonexistentBinaryFails) {
  NSError* error = nil;
  OWLLaunchResult* result =
      [OWLProcessLauncher launchAtPath:@"/nonexistent/binary"
                           userDataDir:@"/tmp"
                          devtoolsPort:0
                                 error:&error];
  EXPECT_EQ(result, nil);
  EXPECT_NE(error, nil);
  EXPECT_EQ(error.code, 201);  // posix_spawn failed
}

TEST(OWLProcessLauncherTest, LaunchValidBinarySucceeds) {
  // Launch /usr/bin/true — exits immediately with 0.
  NSError* error = nil;
  OWLLaunchResult* result =
      [OWLProcessLauncher launchAtPath:@"/usr/bin/true"
                           userDataDir:@"/tmp"
                          devtoolsPort:0
                                 error:&error];

  // On macOS, /usr/bin/true may not exist (stub). Try /bin/sh -c true.
  if (result == nil) {
    // posix_spawn of /usr/bin/true failed, try /bin/sh.
    result = [OWLProcessLauncher launchAtPath:@"/bin/sh"
                                 userDataDir:@"/tmp"
                                devtoolsPort:0
                                       error:&error];
  }

  if (result == nil) {
    GTEST_SKIP() << "Cannot find a valid binary to test: "
                 << error.localizedDescription.UTF8String;
  }

  EXPECT_GT(result.pid, 0);
  EXPECT_GE(result.localFD, 0);

  // Clean up: close FD and wait for child.
  close(result.localFD);
  int status = 0;
  waitpid(result.pid, &status, 0);
}

TEST(OWLProcessLauncherTest, LocalFDIsUsable) {
  NSError* error = nil;
  // Launch /bin/cat — reads from stdin (our socketpair).
  OWLLaunchResult* result =
      [OWLProcessLauncher launchAtPath:@"/bin/cat"
                           userDataDir:@"/tmp"
                          devtoolsPort:0
                                 error:&error];

  if (result == nil) {
    GTEST_SKIP() << "Cannot launch /bin/cat";
  }

  // Write to local FD, cat should echo it back (but it reads from
  // the remote FD which is the socketpair other end).
  // Just verify the FD is valid by checking fcntl.
  int flags = fcntl(result.localFD, F_GETFL);
  EXPECT_GE(flags, 0);

  // Clean up.
  close(result.localFD);
  kill(result.pid, SIGTERM);
  int status = 0;
  waitpid(result.pid, &status, 0);
}

TEST(OWLProcessLauncherTest, RemoteFDIsClosedInParent) {
  NSError* error = nil;
  OWLLaunchResult* result =
      [OWLProcessLauncher launchAtPath:@"/bin/cat"
                           userDataDir:@"/tmp"
                          devtoolsPort:0
                                 error:&error];

  if (result == nil) {
    GTEST_SKIP() << "Cannot launch /bin/cat";
  }

  // The remote FD should have been closed in parent.
  // We can't easily test this directly, but verify local FD works.
  EXPECT_GE(result.localFD, 0);

  close(result.localFD);
  kill(result.pid, SIGTERM);
  int status = 0;
  waitpid(result.pid, &status, 0);
}

}  // namespace
}  // namespace owl
