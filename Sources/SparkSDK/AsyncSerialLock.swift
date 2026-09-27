import Foundation

/// A first-in, first-out async mutex: `run` starts its operation only after every earlier
/// caller's operation has finished. The reference SDK serialises transfer claims the same way
/// (`claimTransferMutex`), so a background claim pass, a swap's claim of its counter-transfer and
/// `withdrawAll`'s claim never race each other for the same transfer.
actor AsyncSerialLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
