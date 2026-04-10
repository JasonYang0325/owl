// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_PROCESS_LAUNCHER_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_PROCESS_LAUNCHER_H_

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OWLBridgeSession;

/// Launches the OWL Host binary and returns a connected OWLBridgeSession.
/// Uses mojo::PlatformChannel + base::LaunchProcess (Mach ports on macOS).
__attribute__((visibility("default")))
@interface OWLProcessLauncher : NSObject

/// Launch owl_host and return a connected session.
/// On macOS, uses Mach port rendezvous for Mojo IPC.
/// Returns nil + error on failure. The child PID is stored internally.
+ (nullable OWLBridgeSession*)launchHostAtPath:(NSString*)hostPath
                                   userDataDir:(NSString*)userDataDir
                                  devtoolsPort:(uint16_t)port
                                  childPID:(pid_t*)outPID
                                         error:(NSError* _Nullable*)error;

@end

NS_ASSUME_NONNULL_END

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_PROCESS_LAUNCHER_H_
