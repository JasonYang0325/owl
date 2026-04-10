// Copyright 2026 AntlerAI. All rights reserved.

#import "third_party/owl/bridge/OWLProcessLauncher.h"

#import "third_party/owl/bridge/OWLBridgeSession.h"
#import "third_party/owl/bridge/OWLMojoThread.h"

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/message_loop/message_pump_type.h"
#include "base/process/launch.h"
#include "base/process/process.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/single_thread_task_executor.h"
#include "mojo/public/cpp/platform/platform_channel.h"
#include "mojo/public/cpp/system/invitation.h"

@implementation OWLProcessLauncher

+ (nullable OWLBridgeSession*)launchHostAtPath:(NSString*)hostPath
                                   userDataDir:(NSString*)userDataDir
                                  devtoolsPort:(uint16_t)port
                                      childPID:(pid_t*)outPID
                                         error:(NSError* _Nullable*)outError {
  // Initialize Mojo runtime (main-thread TaskExecutor + IO thread + IPC support).
  [[OWLMojoThread shared] ensureStarted];

  // 1. Create PlatformChannel (Mach port pair on macOS).
  mojo::PlatformChannel channel;

  // 2. Build command line.
  base::FilePath host_path{[hostPath fileSystemRepresentation]};
  base::CommandLine command_line{host_path};
  command_line.AppendSwitchASCII(
      "user-data-dir", std::string([userDataDir UTF8String]));
  command_line.AppendSwitchASCII(
      "devtools-port", base::NumberToString(port));
  // Disable sandbox for development (owl_host is not sandboxed yet).
  command_line.AppendSwitch("no-sandbox");

  // 3. Prepare launch options with Mach port rendezvous.
  base::LaunchOptions options;
  channel.PrepareToPassRemoteEndpoint(&options, &command_line);

  // 4. Launch child process.
  base::Process process = base::LaunchProcess(command_line, options);
  channel.RemoteProcessLaunchAttempted();

  if (!process.IsValid()) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"OWLBridge" code:201
                                  userInfo:@{NSLocalizedDescriptionKey:
                                      @"Failed to launch owl_host"}];
    }
    return nil;
  }

  if (outPID) {
    *outPID = process.Pid();
  }

  // 5. Send invitation.
  mojo::OutgoingInvitation invitation;
  mojo::ScopedMessagePipeHandle pipe =
      invitation.AttachMessagePipe(uint64_t{0});

  mojo::OutgoingInvitation::Send(
      std::move(invitation),
      process.Handle(),
      channel.TakeLocalEndpoint());

  // 6. Create session from the pipe.
  uint64_t pipeValue = pipe.release().value();
  OWLBridgeSession* session =
      [[OWLBridgeSession alloc] initWithMojoPipe:pipeValue];
  if (!session) {
    if (outError) {
      *outError = [NSError errorWithDomain:@"OWLBridge" code:202
                                  userInfo:@{NSLocalizedDescriptionKey:
                                      @"Failed to create session from pipe"}];
    }
    return nil;
  }

  return session;
}

@end
