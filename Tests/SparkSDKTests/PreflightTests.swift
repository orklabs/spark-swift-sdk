import Foundation
import Testing
@testable import SparkSDK

/// Read-only mainnet preflight: reports balances, leaves and timelocks for the wallets in an
/// env file named by `SPARK_PREFLIGHT_DOTENV`. Never moves funds and never prints secrets.
///
/// Run with the regular integration suites disabled:
///   SPARK_TEST_DOTENV=/dev/null SPARK_PREFLIGHT_DOTENV=$PWD/.env swift test --filter Preflight
@Suite("Preflight", .enabled(if: PreflightConfig.env != nil))
struct PreflightTests {

    /// Optional maintenance steps, each enabled by an environment variable so nothing runs by
    /// accident: SPARK_PREFLIGHT_RENEW=1 renews exhausted leaves, SPARK_PREFLIGHT_CLAIM=1 claims
    /// pending inbound transfers, SPARK_PREFLIGHT_FEE_QUOTE=1 fetches coop-exit fee quotes, and
    /// SPARK_PREFLIGHT_INVOICE_SATS=<n> creates a top-up invoice on wallet A. None of them sends
    /// sats anywhere.
    @Test("Report balances for the configured test wallets", .timeLimit(.minutes(10)))
    func balances() async throws {
        guard let env = PreflightConfig.env else { return }
        let flags = ProcessInfo.processInfo.environment
        var report: [String] = []

        func open(_ key: String, account: Int) async throws -> SparkWallet? {
            guard let mnemonic = env[key], !mnemonic.isEmpty else { return nil }
            let wallet = try SparkWallet(mnemonic: mnemonic, account: account)
            await wallet.start()
            return wallet
        }

        if flags["SPARK_PREFLIGHT_RENEW"] == "1" {
            for (label, key) in [("Wallet A", "SPARK_TEST_WALLET_A_MNEMONIC"), ("Wallet B", "SPARK_TEST_WALLET_B_MNEMONIC")] {
                guard let wallet = try await open(key, account: 0) else { continue }
                do {
                    let result = try await wallet.renewExhaustedLeaves()
                    report.append("RENEW \(label): checked \(result.checked), renewed \(result.renewed), failures: \(result.failures)")
                } catch {
                    report.append("RENEW \(label): failed — \(error)")
                }
                await wallet.close()
            }
        }
        if flags["SPARK_PREFLIGHT_CLAIM"] == "1" {
            for (label, key) in [("Wallet A", "SPARK_TEST_WALLET_A_MNEMONIC"), ("Wallet B", "SPARK_TEST_WALLET_B_MNEMONIC")] {
                guard let wallet = try await open(key, account: 0) else { continue }
                do {
                    let claimed = try await wallet.claimAllPendingTransfers()
                    report.append("CLAIM \(label): claimed \(claimed) pending transfer(s)")
                } catch {
                    report.append("CLAIM \(label): failed — \(error)")
                }
                await wallet.close()
            }
        }

        for (label, key, accountKey) in [
            ("Wallet A", "SPARK_TEST_WALLET_A_MNEMONIC", nil),
            ("Wallet B", "SPARK_TEST_WALLET_B_MNEMONIC", nil),
            ("Static deposit wallet", "SPARK_TEST_STATIC_DEPOSIT_MNEMONIC", "SPARK_TEST_STATIC_DEPOSIT_ACCOUNT"),
        ] as [(String, String, String?)] {
            guard let mnemonic = env[key], !mnemonic.isEmpty else {
                report.append("\(label): not configured")
                continue
            }
            let account = accountKey.flatMap { env[$0] }.flatMap(Int.init) ?? (label == "Static deposit wallet" ? 11 : 0)
            let wallet: SparkWallet
            do {
                wallet = try SparkWallet(mnemonic: mnemonic, account: account)
            } catch {
                report.append("\(label): cannot open wallet — \(error)")
                continue
            }
            await wallet.start()
            defer { Task { await wallet.close() } }

            var leafIdsForQuote: [String] = []
            do {
                let balance = try await wallet.getBalance()
                leafIdsForQuote = balance.leaves.map(\.id)
                let leaves = balance.leaves.sorted { $0.valueSats > $1.valueSats }
                let exhausted = leaves.filter { $0.refundTimelockBlocks <= sparkTimeLockInterval }.count
                let low = leaves.filter { $0.refundTimelockBlocks < 200 }.count
                report.append("""
                \(label) (account \(account))
                  identity:  \(wallet.identityPublicKeyHex)
                  address:   \(wallet.getSparkAddress())
                  available: \(balance.satsBalance.available) sats   owned: \(balance.satsBalance.owned)   incoming: \(balance.satsBalance.incoming)
                  leaves:    \(leaves.count) \(leafSummary(leaves))
                  timelocks: \(low) below renewal threshold, \(exhausted) exhausted
                  tokens:    \(balance.tokenBalances.map { "\($0.tokenMetadata.tokenTicker)=\($0.availableToSendBalance)" }.joined(separator: " "))
                """)
            } catch {
                report.append("\(label) (account \(account)): balance query failed — \(error)")
            }

            if flags["SPARK_PREFLIGHT_FEE_QUOTE"] == "1", !leafIdsForQuote.isEmpty,
               let address = env["SPARK_TEST_STATIC_DEPOSIT_WITHDRAW_ADDRESS"], !address.isEmpty {
                do {
                    let quote = try await wallet.getWithdrawalFeeEstimate(onChainAddress: address, leafIds: leafIdsForQuote)
                    report.append("  coop-exit fee quote (FAST) for all \(leafIdsForQuote.count) leaves to \(address.prefix(12))…: \(quote.feeSats) sats")
                } catch {
                    report.append("  coop-exit fee quote failed — \(error)")
                }
            }
            if label == "Wallet A", let satsText = flags["SPARK_PREFLIGHT_INVOICE_SATS"], let sats = Int64(satsText), sats > 0 {
                do {
                    let invoice = try await wallet.createLightningInvoice(amountSats: sats, memo: "SparkSDK integration test top-up")
                    report.append("  TOP-UP INVOICE (\(sats) sats, expires \(invoice.expiresAt)):\n  \(invoice.paymentRequest)")
                } catch {
                    report.append("  top-up invoice creation failed — \(error)")
                }
            }
            if label == "Static deposit wallet", let address = env["SPARK_TEST_STATIC_DEPOSIT_ADDRESS"], !address.isEmpty {
                do {
                    let utxos = try await wallet.getUtxosForDepositAddress(address: address, excludeClaimed: true)
                    report.append("  static deposit address \(address): \(utxos.count) unclaimed utxo(s) \(utxos.map { "\($0.txid):\($0.vout)" }.joined(separator: " "))")
                } catch {
                    report.append("  static deposit utxo query failed — \(error)")
                }
            }
        }
        if let ln = env["SPARK_TEST_LIGHTNING_ADDRESS"], !ln.isEmpty {
            report.append("External lightning address configured: \(ln)")
        }
        print("\n=== PREFLIGHT REPORT ===\n" + report.joined(separator: "\n") + "\n=== END PREFLIGHT ===\n")
    }
}

/// "value@tl<timelock>/seq=<hex>/rt=<refund tx bytes>" for the first dozen leaves.
private func leafSummary(_ leaves: [SparkLeaf]) -> String {
    let shown = leaves.prefix(12).map { leaf -> String in
        let sequence = (try? SparkWallet.parseSequenceFromRawTx(Data(leaf.node.refundTx))) ?? 0
        return "\(leaf.valueSats)@tl\(leaf.refundTimelockBlocks)/seq=\(String(sequence, radix: 16))/rt=\(leaf.node.refundTx.count)"
    }
    return shown.joined(separator: " ") + (leaves.count > 12 ? " …" : "")
}

enum PreflightConfig {
    /// Parsed env file, or nil when `SPARK_PREFLIGHT_DOTENV` is unset or unreadable.
    static let env: [String: String]? = {
        guard let path = ProcessInfo.processInfo.environment["SPARK_PREFLIGHT_DOTENV"],
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result.isEmpty ? nil : result
    }()
}
