import Foundation

/// Tracks secondary vCPU host threads from launch through complete exit.
///
/// Hypervisor.framework vCPUs must be destroyed only after the thread that
/// owns each `hv_vcpu_run` loop has returned.  This coordinator deliberately
/// tracks the host-thread lifetime, rather than merely whether a vCPU is
/// outside `hv_vcpu_run` at an instant.
nonisolated final class FluxSecondaryVCPUShutdownCoordinator: @unchecked Sendable {

    private let condition = NSCondition()
    private var launchedIDs = Set<Int>()
    private var exitedIDs = Set<Int>()

    /// Registers a secondary thread before it is detached.  This also covers
    /// a shutdown racing with startup: the pending thread is still required to
    /// acknowledge its exit before VM destruction proceeds.
    func registerLaunch(id: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !launchedIDs.contains(id) else { return false }
        launchedIDs.insert(id)
        return true
    }

    /// Records the terminal point of the owning host thread.  It is safe to
    /// call more than once so error and normal cleanup paths can share it.
    func markExited(id: Int) {
        condition.lock()
        exitedIDs.insert(id)
        condition.broadcast()
        condition.unlock()
    }

    /// Waits without holding any VM, vCPU, or device lock needed by a
    /// secondary loop's exit path.
    func waitForAllExits(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !launchedIDs.isSubset(of: exitedIDs) {
            if !condition.wait(until: deadline) {
                return launchedIDs.isSubset(of: exitedIDs)
            }
        }
        return true
    }

    /// Used only after a reported timeout.  Keeping the owning VM run alive
    /// prevents the runtime lock from being released while a vCPU may still
    /// be executing.
    func waitUntilAllExited() {
        condition.lock()
        while !launchedIDs.isSubset(of: exitedIDs) {
            condition.wait()
        }
        condition.unlock()
    }

    var outstandingIDs: [Int] {
        condition.lock()
        defer { condition.unlock() }
        return launchedIDs.subtracting(exitedIDs).sorted()
    }
}
