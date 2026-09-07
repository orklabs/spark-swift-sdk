import Foundation
import Testing
@testable import SparkSDK

// Temporary diagnostic (untracked): consolidate the SPARK_DIAG_MNEMONIC wallet
// for real and print the outcome. Off-chain SSP swap; sats stay in the wallet.
@Suite("ConsolidationDiag", .enabled(if: ProcessInfo.processInfo.environment["SPARK_DIAG_MNEMONIC"] != nil))
struct ConsolidationDiag {
    @Test("Consolidate account 0 live", .timeLimit(.minutes(5)))
    func run() async throws {
        let mnemonic = ProcessInfo.processInfo.environment["SPARK_DIAG_MNEMONIC"]!
        let wallet = try SparkWallet(mnemonic: mnemonic, account: 0)
        await wallet.start()
        defer { Task { await wallet.close() } }

        let result = try await wallet.consolidateLeaves()
    // swiftlint:disable:next line_length
        print("CONSOL: \(result.leavesBefore) -> \(result.leavesAfter) leaves, \(result.totalSatsBefore) -> \(result.totalSatsAfter) sats, fee \(result.feeSats), rounds \(result.rounds), skipped \(result.skippedLeaves)")

        let snap = try await wallet.getRecoverySnapshot()
        let json = try JSONEncoder().encode(snap)
        print("CONSOL: bundle now \(snap.leaves.count) leaves / \(snap.nodes.count) ancestors / ≈ \(json.count / 1024) KB")
    }
}
