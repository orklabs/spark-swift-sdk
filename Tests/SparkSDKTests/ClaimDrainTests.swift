import Foundation
import Testing
@testable import SparkSDK

/// The claim pass ported from the reference SDK's `claimTransfers`
/// (`spark-wallet-claim-transfers.test.ts`). The Swift SDK has no server-time snapshot yet, so
/// the reference's fallback mode applies: pages of 25, restart from the head after progress,
/// advance otherwise, at most 100 pages per pass.
@Suite("Pending transfer claim pass")
struct ClaimDrainTests {

    static func transfer(_ id: String, status: Spark_TransferStatus = .senderKeyTweaked) -> Spark_Transfer {
        var transfer = Spark_Transfer()
        transfer.id = id
        transfer.status = status
        transfer.type = .transfer
        return transfer
    }

    /// Pending transfers that leave the set once claimed, as they do on the operators.
    actor PendingServer {
        private(set) var pending: [Spark_Transfer]
        private(set) var queries: [(limit: Int, offset: Int)] = []
        private(set) var claimAttempts: [String] = []
        private let failing: Set<String>

        init(_ pending: [Spark_Transfer], failing: Set<String> = []) {
            self.pending = pending
            self.failing = failing
        }

        func page(limit: Int, offset: Int) -> [Spark_Transfer] {
            queries.append((limit, offset))
            guard offset < pending.count else { return [] }
            return Array(pending[offset..<min(offset + limit, pending.count)])
        }

        func claim(_ transfer: Spark_Transfer) throws {
            claimAttempts.append(transfer.id)
            if failing.contains(transfer.id) {
                throw SparkError.untrustedResponse("sender signature on \(transfer.id) does not verify")
            }
            pending.removeAll { $0.id == transfer.id }
        }
    }

    /// Answers queries from a script (the last answer repeats) and never removes anything.
    actor ScriptedServer {
        private var script: [[Spark_Transfer]]
        private(set) var queries: [(limit: Int, offset: Int)] = []
        private(set) var claimAttempts: [String] = []
        private let succeeding: (String) -> Bool

        init(_ script: [[Spark_Transfer]], succeeding: @escaping @Sendable (String) -> Bool = { _ in true }) {
            self.script = script
            self.succeeding = succeeding
        }

        func page(limit: Int, offset: Int) -> [Spark_Transfer] {
            queries.append((limit, offset))
            return script.count > 1 ? script.removeFirst() : script[0]
        }

        func claim(_ transfer: Spark_Transfer) throws {
            claimAttempts.append(transfer.id)
            guard succeeding(transfer.id) else {
                throw SparkError.invalidResponse("failed to claim \(transfer.id)")
            }
        }
    }

    static func run(_ server: PendingServer) async throws -> PendingTransferClaim {
        try await PendingTransferDrain.run(
            fetch: { try await server.page(limit: $0, offset: $1) },
            claim: { try await server.claim($0) }
        )
    }

    static func run(_ server: ScriptedServer) async throws -> PendingTransferClaim {
        try await PendingTransferDrain.run(
            fetch: { await server.page(limit: $0, offset: $1) },
            claim: { try await server.claim($0) }
        )
    }

    @Test("Drains pending transfers from the head in 25-transfer batches")
    func drainsFromTheHead() async throws {
        let first = (1...25).map { Self.transfer("transfer-\($0)") }
        let server = ScriptedServer([first, [Self.transfer("transfer-26")]])
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == (1...26).map { "transfer-\($0)" })
        #expect(result.failures.isEmpty)
        #expect(await server.queries.map(\.limit) == [25, 25])
        #expect(await server.queries.map(\.offset) == [0, 0])
    }

    @Test("Drains a shrinking server-side pending set across several batches")
    func drainsShrinkingSet() async throws {
        let server = PendingServer((1...76).map { Self.transfer("server-transfer-\($0)") })
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == (1...76).map { "server-transfer-\($0)" })
        #expect(await server.pending.isEmpty)
        #expect(await server.queries.map(\.offset) == [0, 0, 0, 0])
        #expect(await server.queries.map(\.limit) == [25, 25, 25, 25])
        #expect(await server.claimAttempts.count == 76)
    }

    @Test("Restarts from the head after partially claiming a full batch, skipping non-claimable statuses")
    func restartsFromTheHead() async throws {
        let skipped = Self.transfer("server-transfer-skipped", status: .expired)
        let server = PendingServer([skipped] + (1...50).map { Self.transfer("server-transfer-\($0)") })
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == (1...50).map { "server-transfer-\($0)" })
        #expect(await server.pending.map(\.id) == [skipped.id])
        #expect(await server.queries.map(\.offset) == [0, 0, 0])
        #expect(await server.claimAttempts.count == 50)
    }

    @Test("Skips a non-claimable head batch to reach later claimable transfers")
    func skipsNonClaimableHead() async throws {
        let expired = (1...25).map { Self.transfer("expired-\($0)", status: .expired) }
        let server = ScriptedServer([expired, [Self.transfer("claimable-later")]])
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == ["claimable-later"])
        #expect(await server.queries.map(\.offset) == [0, 25])
    }

    @Test("Skips a fully failing head batch to reach later claimable transfers")
    func skipsFailingHead() async throws {
        let failing = (1...25).map { Self.transfer("transfer-\($0)") }
        let server = ScriptedServer([failing, [Self.transfer("transfer-26")]]) { $0 == "transfer-26" }
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == ["transfer-26"])
        #expect(result.failures.map(\.transferId) == (1...25).map { "transfer-\($0)" })
        #expect(await server.queries.map(\.offset) == [0, 25])
        #expect(await server.claimAttempts.count == 26)
    }

    @Test("A transfer that cannot be claimed never blocks the ones behind it")
    func refusedTransferDoesNotBlock() async throws {
        // Anyone can create a pending transfer the SDK refuses: the operators store the per-leaf
        // sender signature without verifying it. Before this fix the pass stopped at the first one.
        let server = PendingServer(
            [Self.transfer("refused")] + (1...30).map { Self.transfer("good-\($0)") },
            failing: ["refused"]
        )
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == (1...30).map { "good-\($0)" })
        #expect(result.failures.map(\.transferId) == ["refused"])
        #expect(await server.pending.map(\.id) == ["refused"])
        // Tried once per pass, not once per page.
        #expect(await server.claimAttempts.filter { $0 == "refused" }.count == 1)
    }

    @Test("The pass reports the leaves of the transfers it claimed, for the renewal that follows")
    func claimedLeaves() async throws {
        func withLeaves(_ id: String, _ leafIds: [String]) -> Spark_Transfer {
            var transfer = Self.transfer(id)
            transfer.leaves = leafIds.map { leafId in
                var transferLeaf = Spark_TransferLeaf()
                transferLeaf.leaf.id = leafId
                return transferLeaf
            }
            return transfer
        }
        let server = PendingServer(
            [withLeaves("t1", ["a", "b"]), withLeaves("refused", ["x"]), withLeaves("t2", ["c"])],
            failing: ["refused"]
        )
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == ["t1", "t2"])
        #expect(result.claimedLeafIds == ["a", "b", "c"])
    }

    @Test("Scans through unclaimable pages for at most 100 batches")
    func boundsUnclaimableScan() async throws {
        let expired = (1...25).map { Self.transfer("expired-loop-\($0)", status: .expired) }
        let server = ScriptedServer([expired])
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds.isEmpty)
        #expect(await server.queries.count == PendingTransferDrain.maxBatches)
    }

    @Test("A server that never shrinks is drained for at most 100 batches, claiming each transfer once")
    func boundsNonShrinkingServer() async throws {
        // The reference SDK re-claims the same 25 every batch here; one attempt per pass suffices.
        let batch = (1...25).map { Self.transfer("loop-\($0)") }
        let server = ScriptedServer([batch])
        let result = try await Self.run(server)
        #expect(result.claimedTransferIds == batch.map(\.id))
        #expect(await server.queries.count == PendingTransferDrain.maxBatches)
    }

    @Test("Only the reference SDK's claimable statuses are claimed")
    func claimableStatuses() {
        #expect(PendingTransferDrain.claimableStatuses == [
            .senderKeyTweaked, .receiverKeyTweaked, .receiverRefundSigned,
            .receiverKeyTweakApplied, .receiverKeyTweakLocked,
        ])
        for status: Spark_TransferStatus in [.senderInitiated, .senderKeyTweakPending, .completed, .expired, .returned,
                                             .senderInitiatedCoordinator, .applyingSenderKeyTweak] {
            #expect(!PendingTransferDrain.claimableStatuses.contains(status))
        }
    }

    @Test("Claims never run concurrently")
    func claimsAreSerialised() async throws {
        actor Recorder {
            var running = 0
            var maxRunning = 0
            var order: [Int] = []
            func enter(_ index: Int) { running += 1; maxRunning = max(maxRunning, running); order.append(index) }
            func leave() { running -= 1 }
        }
        let lock = AsyncSerialLock()
        let recorder = Recorder()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await lock.run {
                        await recorder.enter(index)
                        try await Task.sleep(for: .milliseconds(5))
                        await recorder.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await recorder.maxRunning == 1)
        #expect(await recorder.order.count == 8)
    }
}
