import Foundation
import Testing
@testable import SparkSDK

// Temporary diagnostic (delete after use): given SPARK_DIAG_MNEMONIC, scan
// account indices for balances and run getRecoverySnapshot on funded ones,
// printing bundle-size stats. Read-only — nothing is signed or moved.
@Suite("SnapshotDiag", .enabled(if: ProcessInfo.processInfo.environment["SPARK_DIAG_MNEMONIC"] != nil))
struct SnapshotDiag {
    @Test("Scan accounts and measure snapshot sizes", .timeLimit(.minutes(10)))
    func run() async throws {
        let mnemonic = ProcessInfo.processInfo.environment["SPARK_DIAG_MNEMONIC"]!
        for account in 0...40 {
            let wallet = try SparkWallet(mnemonic: mnemonic, account: account)
            await wallet.start()
            defer { Task { await wallet.close() } }
            do {
                let balance = try await wallet.getBalance()
                guard balance.satsBalance.owned > 0 || !balance.leaves.isEmpty else { continue }
                print("DIAG account \(account): available=\(balance.satsBalance.available) owned=\(balance.satsBalance.owned) leaves=\(balance.leaves.count)")
                do {
                    let snap = try await wallet.getRecoverySnapshot()
                    let json = try JSONEncoder().encode(snap)
                    print("DIAG account \(account): SNAPSHOT OK — \(snap.leaves.count) leaves / \(snap.totalLeafSats) sats / \(snap.nodes.count) ancestors / bundle ≈ \(json.count / 1024) KB")
                } catch {
                    print("DIAG account \(account): SNAPSHOT FAILED — \(String(describing: error))")
                }
            } catch {
                print("DIAG account \(account): balance failed — \(String(describing: error))")
            }
        }
        print("DIAG scan complete (0...40)")
    }
}
