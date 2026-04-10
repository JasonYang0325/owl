import Foundation
import os
#if canImport(OWLBridge)
import OWLBridge
#endif

/// Swift wrapper around OWLBridge C-ABI functions.
/// Provides async/await interface for launching Host and Mojo IPC.
enum OWLBridgeSwift {

    /// Thread-safe idempotent guard: mojo::core::Init() must only be called once.
    /// Multiple callers (BrowserViewModel, OWLTestBridge, UITest) may
    /// share the same process in `swift test`.
    /// Protected by OSAllocatedUnfairLock for safe concurrent access.
    private static let lock = OSAllocatedUnfairLock(initialState: false)

    /// Initialize Mojo runtime. Safe to call from any thread, any number of times.
    /// Only the first call actually invokes OWLBridge_Initialize(); subsequent
    /// calls are no-ops.
    static func initialize() {
        let alreadyDone = lock.withLock { (initialized: inout Bool) -> Bool in
            if initialized { return true }
            initialized = true
            return false
        }
        if alreadyDone { return }
        OWLBridge_Initialize()
    }

    /// Whether OWLBridge_Initialize() has been invoked in this process.
    /// Used by bridge wrappers to avoid calling C-ABI APIs that require
    /// initialized Mojo runtime in unit-test mock mode.
    static func isInitializedInProcess() -> Bool {
        lock.withLock { (initialized: inout Bool) -> Bool in
            initialized
        }
    }

    /// Launch owl_host process. Returns (session pipe handle, child PID).
    static func launchHost(path: String, userDataDir: String, port: UInt16) async throws -> (pipe: UInt64, pid: pid_t) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(UInt64, pid_t), Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            path.withCString { pathPtr in
                userDataDir.withCString { dirPtr in
                    OWLBridge_LaunchHost(pathPtr, dirPtr, port, { pipe, pid, errMsg, ctx in
                        let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                            as! CheckedContinuation<(UInt64, pid_t), Error>
                        if let errMsg {
                            cont.resume(throwing: NSError(
                                domain: "OWLBridge", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                        } else {
                            cont.resume(returning: (pipe, pid))
                        }
                    }, ctx)
                }
            }
        }
    }

    /// Close a Mojo handle.
    static func closeHandle(_ handle: UInt64) {
        OWLBridge_CloseHandle(handle)
    }

    // GetHostInfo removed — use OWLBridgeSession.getHostInfo() instead.

    /// Check if input looks like a URL.
    static func inputLooksLikeURL(_ input: String) -> Bool {
        let result = input.withCString { ptr -> Int32 in
            return OWLBridge_InputLooksLikeURL(ptr)
        }
        return result != 0
    }
}
