import Foundation
import Darwin

public final class ProcessGuard {
    public private(set) var pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }

    @discardableResult
    public func terminate(gracePeriod: TimeInterval = 2.0, killPeriod: TimeInterval = 2.0) -> Bool {
        guard pid > 0 else { return true }

        if reapIfExited(pid) {
            pid = 0
            return true
        }

        if kill(pid, SIGTERM) == -1 && errno == ESRCH {
            pid = 0
            return true
        }

        let termDeadline = Date().addingTimeInterval(gracePeriod)
        while Date() < termDeadline {
            if reapIfExited(pid) {
                self.pid = 0
                return true
            }
            usleep(50_000)
        }

        _ = kill(pid, SIGKILL)
        let killDeadline = Date().addingTimeInterval(killPeriod)
        while Date() < killDeadline {
            if reapIfExited(pid) {
                self.pid = 0
                return true
            }
            usleep(50_000)
        }

        return false
    }

    deinit {
        _ = terminate(gracePeriod: 0.5, killPeriod: 0.5)
    }
}

private func reapIfExited(_ pid: pid_t) -> Bool {
    var status: Int32 = 0
    let ret = waitpid(pid, &status, WNOHANG)
    if ret == pid {
        return true
    }
    if ret == 0 {
        return false
    }
    return errno == ECHILD || errno == ESRCH
}
