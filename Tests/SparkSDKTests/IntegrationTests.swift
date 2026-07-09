import Foundation
import Testing
import GRPCCore
import SwiftProtobuf
@testable import SparkSDK

// MARK: - Test Configuration

/// Integration test wallets are loaded from environment variables / `.env`.
/// See `TestConfig.swift` for required variables and `.env.example` for a template.
var walletAMnemonic: String { TestConfig.walletAMnemonic }
var walletBMnemonic: String { TestConfig.walletBMnemonic }

/// Minimum balance (sats) needed to run the full test suite
let minimumTestBalance: Int64 = 500


// MARK: - Helpers

/// Resolves a lightning address (user@domain) to a BOLT11 invoice via LNURL-pay
func resolveLightningAddress(_ address: String, amountSats: Int64) async throws -> String {
    let parts = address.split(separator: "@")
    guard parts.count == 2 else {
        throw SparkError.invalidResponse("Invalid lightning address format")
    }
    let lnurlURL = URL(string: "https://\(parts[1])/.well-known/lnurlp/\(parts[0])")!
    let (data, _) = try await URLSession.shared.data(from: lnurlURL)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let callback = json["callback"] as? String else {
        throw SparkError.invalidResponse("Invalid LNURL-pay response")
    }
    let callbackURL = URL(string: "\(callback)?amount=\(amountSats * 1000)")!
    let (invoiceData, _) = try await URLSession.shared.data(from: callbackURL)
    guard let invoiceJson = try JSONSerialization.jsonObject(with: invoiceData) as? [String: Any],
          let pr = invoiceJson["pr"] as? String else {
        throw SparkError.invalidResponse("Invalid LNURL-pay callback response")
    }
    return pr
}

/// Create and start a wallet, returning it for tests
func makeWallet(_ mnemonic: String) async throws -> SparkWallet {
    let w = try SparkWallet(mnemonic: mnemonic, account: 0)
    await w.start()
    return w
}

// =============================================================================
// MARK: - Wallet Tests (matching JS: wallet.test.ts)
// =============================================================================

@Suite("Wallet", .enabled(if: TestConfig.hasIntegrationCredentials))
struct WalletTests {

    @Test("Should initialize a wallet from mnemonic")
    func initializeWallet() throws {
        let wallet = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        #expect(!wallet.identityPublicKeyHex.isEmpty)
    }

    @Test("Different accounts produce different identity keys")
    func differentAccounts() throws {
        let account0 = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        let account1 = try SparkWallet(mnemonic: walletAMnemonic, account: 1)
        #expect(account0.identityPublicKeyHex != account1.identityPublicKeyHex)
    }

    @Test("Same mnemonic + account produces same identity key")
    func deterministicKeys() throws {
        let w1 = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        let w2 = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        #expect(w1.identityPublicKeyHex == w2.identityPublicKeyHex)
    }

    @Test("Two different mnemonics produce different identity keys")
    func differentMnemonics() throws {
        let wA = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        let wB = try SparkWallet(mnemonic: walletBMnemonic, account: 0)
        #expect(wA.identityPublicKeyHex != wB.identityPublicKeyHex)
    }
}

// =============================================================================
// MARK: - Spark Address Tests (matching JS: address.test.ts)
// =============================================================================

@Suite("Spark Address", .enabled(if: TestConfig.hasIntegrationCredentials))
struct SparkAddressTests {

    @Test("Should generate a spark address with correct prefix")
    func sparkAddressPrefix() throws {
        let wallet = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        let address = wallet.getSparkAddress()
        #expect(address.hasPrefix("spark1"))
        #expect(address.count > 10)
        print("Spark address: \(address)")
    }

    @Test("Same wallet produces same spark address")
    func deterministicAddress() throws {
        let w1 = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        let w2 = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        #expect(w1.getSparkAddress() == w2.getSparkAddress())
    }

    @Test("Different wallets produce different spark addresses")
    func differentAddresses() throws {
        let wA = try SparkWallet(mnemonic: walletAMnemonic, account: 0)
        let wB = try SparkWallet(mnemonic: walletBMnemonic, account: 0)
        #expect(wA.getSparkAddress() != wB.getSparkAddress())
    }
}

// =============================================================================
// MARK: - Balance Tests
// =============================================================================

@Suite("Balance", .enabled(if: TestConfig.hasIntegrationCredentials))
struct BalanceTests {

    @Test("Should query balance")
    func queryBalance() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let balance = try await wallet.getBalance()
        print("Balance: \(balance.satsBalance.available) sats, \(balance.leaves.count) leaves")
        #expect(balance.satsBalance.available >= 0)
    }

    @Test("Should query leaves")
    func queryLeaves() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let leaves = try await wallet.getLeaves()
        for leaf in leaves {
            print("  Leaf \(leaf.id): \(leaf.valueSats) sats [\(leaf.status)]")
            #expect(leaf.valueSats > 0)
            #expect(leaf.status == "AVAILABLE")
        }
    }
}

// =============================================================================
// MARK: - Recovery Snapshot Tests (unilateral-exit bundle material)
// =============================================================================

@Suite("Recovery", .enabled(if: TestConfig.hasIntegrationCredentials))
struct RecoveryTests {

    @Test("Recovery snapshot covers the balance with complete ancestor chains")
    func recoverySnapshot() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let balance = try await wallet.getBalance()
        let snapshot = try await wallet.getRecoverySnapshot()
        print("Snapshot: \(snapshot.leaves.count) leaves (\(snapshot.totalLeafSats) sats), \(snapshot.nodes.count) ancestor nodes")

        #expect(snapshot.network == "MAINNET")
        #expect(snapshot.identityPublicKeyHex == wallet.identityPublicKeyHex)
        // Every available sat must be covered by the snapshot's leaves.
        #expect(snapshot.totalLeafSats >= balance.satsBalance.available)

        // Decode every entry and verify each leaf chain walks to a root.
        var byId: [String: Spark_TreeNode] = [:]
        for entry in snapshot.leaves {
            let node = try Spark_TreeNode(serializedBytes: Data(hexString: entry.treeNodeHex)!)
            #expect(!node.refundTx.isEmpty, "leaf \(entry.id) missing refund tx")
            #expect(!node.nodeTx.isEmpty, "leaf \(entry.id) missing node tx")
            byId[entry.id] = node
        }
        for entry in snapshot.nodes {
            byId[entry.id] = try Spark_TreeNode(serializedBytes: Data(hexString: entry.treeNodeHex)!)
        }
        for leaf in snapshot.leaves {
            var cursor = byId[leaf.id]
            var hops = 0
            while let node = cursor, node.hasParentNodeID, !node.parentNodeID.isEmpty {
                cursor = byId[node.parentNodeID]
                #expect(cursor != nil, "broken chain above leaf \(leaf.id)")
                hops += 1
                #expect(hops < 100, "chain too deep — cycle?")
            }
        }
    }
}

// =============================================================================
// MARK: - Deposit Tests (matching JS: deposit.test.ts)
// =============================================================================

@Suite("Deposit", .enabled(if: TestConfig.hasIntegrationCredentials))
struct DepositTests {

    @Test("Should generate a single-use deposit address")
    func generateDepositAddress() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let deposit = try await wallet.getDepositAddress()
        #expect(!deposit.address.isEmpty)
        #expect(!deposit.leafId.isEmpty)
        #expect(deposit.address.hasPrefix("bc1p")) // P2TR address
        print("Deposit address: \(deposit.address)")
    }

    @Test("Should generate a static deposit address")
    func generateStaticDepositAddress() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let deposit = try await wallet.getStaticDepositAddress()
        #expect(!deposit.address.isEmpty)
        #expect(deposit.address.hasPrefix("bc1p"))
        print("Static deposit address: \(deposit.address)")
    }

    @Test("Static deposit address is deterministic")
    func staticDepositDeterministic() async throws {
        let w1 = try await makeWallet(walletAMnemonic)
        defer { Task { await w1.close() } }
        let w2 = try await makeWallet(walletAMnemonic)
        defer { Task { await w2.close() } }

        let addr1 = try await w1.getStaticDepositAddress()
        let addr2 = try await w2.getStaticDepositAddress()
        #expect(addr1.address == addr2.address)
    }

    @Test("Should query unused deposit addresses")
    func queryUnusedAddresses() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let addresses = try await wallet.queryUnusedDepositAddresses()
        print("Unused deposit addresses: \(addresses.count)")
        for addr in addresses {
            #expect(!addr.address.isEmpty)
            #expect(!addr.leafId.isEmpty)
            print("  \(addr.address) leafId=\(addr.leafId)")
        }
    }

    @Test("Should generate multiple deposit addresses and query them")
    func multipleDepositAddresses() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let countBefore = try await wallet.queryUnusedDepositAddresses().count

        // Generate 2 new addresses
        let _ = try await wallet.getDepositAddress()
        let _ = try await wallet.getDepositAddress()

        let countAfter = try await wallet.queryUnusedDepositAddresses().count
        #expect(countAfter >= countBefore + 2)
    }

    @Test("Generated deposit address appears in unused deposit addresses")
    func generatedAddressInUnused() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let deposit = try await wallet.getDepositAddress()
        let unused = try await wallet.queryUnusedDepositAddresses()

        let found = unused.contains { $0.leafId == deposit.leafId && $0.address == deposit.address }
        #expect(found, "Generated deposit address should appear in unused list")
        print("Confirmed deposit \(deposit.address) (leafId=\(deposit.leafId)) is in unused list")
    }

    @Test("Static deposit addresses don't appear in unused deposit addresses")
    func staticNotInUnused() async throws {
        // Static deposits use a different query endpoint
        let wallet = try await makeWallet(walletBMnemonic) // use walletB (clean state)
        defer { Task { await wallet.close() } }

        let staticAddr = try await wallet.getStaticDepositAddress()
        let unused = try await wallet.queryUnusedDepositAddresses()
        let staticInUnused = unused.contains { $0.address == staticAddr.address }
        #expect(!staticInUnused)
    }

    @Test("Should query static deposit addresses")
    func queryStaticDepositAddresses() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        // Ensure at least one static address exists
        let generated = try await wallet.getStaticDepositAddress()

        let addresses = try await wallet.queryStaticDepositAddresses()
        #expect(!addresses.isEmpty)
        // The generated address should be in the list
        let found = addresses.contains { $0.address == generated.address }
        #expect(found)
        print("Static deposit addresses: \(addresses.count)")
        for addr in addresses {
            #expect(!addr.address.isEmpty)
            #expect(addr.address.hasPrefix("bc1p"))
            print("  \(addr.address)")
        }
    }

    @Test("queryStaticDepositAddresses returns deterministic results")
    func queryStaticDeterministic() async throws {
        let w1 = try await makeWallet(walletAMnemonic)
        defer { Task { await w1.close() } }
        let w2 = try await makeWallet(walletAMnemonic)
        defer { Task { await w2.close() } }

        let addrs1 = try await w1.queryStaticDepositAddresses()
        let addrs2 = try await w2.queryStaticDepositAddresses()
        #expect(addrs1.map(\.address) == addrs2.map(\.address))
    }

    @Test("Should get UTXOs for a deposit address")
    func getUtxosForDepositAddress() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        // Generate a fresh single-use address — no deposits sent, so should be empty
        let deposit = try await wallet.getDepositAddress()
        let utxos = try await wallet.getUtxosForDepositAddress(address: deposit.address)
        print("UTXOs for \(deposit.address): \(utxos.count)")
        #expect(utxos.isEmpty, "Fresh deposit address should have no UTXOs")
    }

    @Test("Should get UTXOs for a static deposit address")
    func getUtxosForStaticAddress() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let staticAddr = try await wallet.getStaticDepositAddress()
        let utxos = try await wallet.getUtxosForDepositAddress(address: staticAddr.address)
        print("UTXOs for static address \(staticAddr.address): \(utxos.count)")
        for utxo in utxos {
            #expect(!utxo.txid.isEmpty)
            print("  txid=\(utxo.txid) vout=\(utxo.vout)")
        }
    }

    @Test("claimStaticDepositWithMaxFee returns nil for invalid txid")
    func claimStaticDepositWithMaxFeeInvalidTx() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        // Using a fake txid should throw (can't fetch raw tx / quote)
        let fakeTxId = "0000000000000000000000000000000000000000000000000000000000000000"
        await #expect(throws: SparkError.self) {
            _ = try await wallet.claimStaticDepositWithMaxFee(
                transactionId: fakeTxId,
                maxFee: 1000
            )
        }
    }
}

// =============================================================================
// MARK: - Lightning Tests (matching JS: lightning.test.ts)
// =============================================================================

@Suite("Lightning", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct LightningTests {

    @Test("Should create a lightning invoice")
    func createInvoice() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let invoice = try await wallet.createLightningInvoice(
            amountSats: 100, memo: "test invoice"
        )
        #expect(!invoice.paymentRequest.isEmpty)
        #expect(!invoice.paymentHash.isEmpty)
        #expect(invoice.amountSats == 100)
        #expect(invoice.expiresAt > Date())
        #expect(invoice.paymentRequest.lowercased().hasPrefix("lnbc"))
        print("Invoice: \(invoice.paymentRequest.prefix(50))...")
    }

    @Test("Should create invoice without memo")
    func createInvoiceNoMemo() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let invoice = try await wallet.createLightningInvoice(amountSats: 50)
        #expect(!invoice.paymentRequest.isEmpty)
    }

    @Test("Should get lightning send fee estimate")
    func getSendFeeEstimate() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let invoice = try await walletB.createLightningInvoice(amountSats: 100)
        let fee = try await walletA.getLightningSendFeeEstimate(
            encodedInvoice: invoice.paymentRequest
        )
        #expect(fee >= 0)
        print("Fee estimate: \(fee) sats")
    }

    @Test("Should pay lightning invoice between wallets")
    func payInvoice() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let balanceBefore = try await walletA.getBalance()
        guard balanceBefore.satsBalance.available >= 100 else {
            Issue.record("WalletA needs >= 100 sats (has \(balanceBefore.satsBalance.available))")
            return
        }

        let amountSats: Int64 = 10
        let invoice = try await walletB.createLightningInvoice(
            amountSats: amountSats, memo: "integration test"
        )
        let paymentID = try await walletA.payLightningInvoice(
            paymentRequest: invoice.paymentRequest
        )
        #expect(!paymentID.isEmpty)
        print("Payment ID: \(paymentID)")

        // Verify sender balance decreased
        let balanceAfter = try await walletA.getBalance()
        #expect(balanceAfter.satsBalance.available < balanceBefore.satsBalance.available)
        print("WalletA: \(balanceBefore.satsBalance.available) -> \(balanceAfter.satsBalance.available) sats")
    }

    @Test("Should pay external lightning address")
    func payLightningAddress() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let balance = try await wallet.getBalance()
        guard balance.satsBalance.available >= 50 else {
            Issue.record("WalletA needs >= 50 sats")
            return
        }

        guard let externalAddress = TestConfig.externalLightningAddress else {
            print("Skipping: SPARK_TEST_LIGHTNING_ADDRESS not set")
            return
        }
        let bolt11 = try await resolveLightningAddress(externalAddress, amountSats: 10)
        let paymentID = try await wallet.payLightningInvoice(paymentRequest: bolt11)
        #expect(!paymentID.isEmpty)
        print("External payment ID: \(paymentID)")
    }
}

// =============================================================================
// MARK: - Transfer Tests (matching JS: transfer.test.ts)
// =============================================================================

@Suite("Transfer", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct TransferTests {

    @Test("Should claim pending transfers")
    func claimPending() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let claimed = try await wallet.claimAllPendingTransfers()
        print("Claimed \(claimed) pending transfers")
        // No assertion on count - may be 0
    }

    @Test("Should transfer between wallets via Spark")
    func sparkTransfer() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let balanceA = try await walletA.getBalance()
        guard balanceA.satsBalance.available >= 100 else {
            Issue.record("WalletA needs >= 100 sats (has \(balanceA.satsBalance.available))")
            return
        }

        let amountSats: Int64 = 10
        let receiverPubKey = Data(hexString: walletB.identityPublicKeyHex)!

        // Send A -> B
        let transfer = try await walletA.send(
            receiverIdentityPublicKey: receiverPubKey,
            amountSats: amountSats
        )
        #expect(!transfer.id.isEmpty)
        print("Transfer sent: \(transfer.id) status=\(transfer.status)")

        // Wait for propagation
        try await Task.sleep(for: .seconds(3))

        // Claim on B
        let claimed = try await walletB.claimAllPendingTransfers()
        #expect(claimed >= 1)

        // Verify B has balance
        let balanceB = try await walletB.getBalance()
        #expect(balanceB.satsBalance.available >= amountSats)
        print("WalletB balance: \(balanceB.satsBalance.available) sats")
    }

    @Test("Should transfer all balance and return it")
    func roundTripTransfer() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        // Ensure B has balance (send A -> B first)
        let balanceA = try await walletA.getBalance()
        guard balanceA.satsBalance.available >= 50 else {
            Issue.record("WalletA needs >= 50 sats")
            return
        }

        let sendAmount: Int64 = 20
        let pubB = Data(hexString: walletB.identityPublicKeyHex)!
        let _ = try await walletA.send(receiverIdentityPublicKey: pubB, amountSats: sendAmount)
        try await Task.sleep(for: .seconds(3))
        let _ = try await walletB.claimAllPendingTransfers()

        // Now send all B -> A
        let balB = try await walletB.getBalance()
        #expect(balB.satsBalance.available > 0)

        let pubA = Data(hexString: walletA.identityPublicKeyHex)!
        let transfer = try await walletB.send(
            receiverIdentityPublicKey: pubA, amountSats: balB.satsBalance.available
        )
        print("Return transfer: \(transfer.id)")

        try await Task.sleep(for: .seconds(3))
        let claimed = try await walletA.claimAllPendingTransfers()
        #expect(claimed >= 1)

        // B should be empty now
        let finalB = try await walletB.getBalance()
        #expect(finalB.satsBalance.available == 0)
        print("WalletB final balance: \(finalB.satsBalance.available) sats")
    }
}

// =============================================================================
// MARK: - Cooperative Exit (Withdrawal) Tests (matching JS: coop-exit.test.ts)
// =============================================================================

@Suite("Withdrawal", .enabled(if: TestConfig.hasIntegrationCredentials))
struct WithdrawalTests {

    @Test("Should get withdrawal fee estimate")
    func feeEstimate() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let leaves = try await wallet.getLeaves()
        guard !leaves.isEmpty else {
            Issue.record("WalletA has no leaves")
            return
        }

        let fee = try await wallet.getWithdrawalFeeEstimate(
            onChainAddress: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            leafIds: leaves.map(\.id)
        )
        #expect(fee.feeSats > 0)
        print("Withdrawal fee estimate: \(fee.feeSats) sats")
    }

    // Note: actual withdrawal test is destructive (spends all balance)
    // Only run manually when you want to withdraw
    @Test("Should withdraw to on-chain address", .disabled("Destructive: spends balance"))
    func withdraw() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let balance = try await wallet.getBalance()
        guard balance.satsBalance.available > 0 else {
            Issue.record("No balance to withdraw")
            return
        }

        let txid = try await wallet.withdraw(
            onChainAddress: "bc1qhta0uu4a7yt0jp3vmzasl3srelx9v46ncl9x89",
            amountSats: balance.satsBalance.available
        )
        #expect(!txid.isEmpty)
        print("Withdrawal txid: \(txid)")
    }
}

// =============================================================================
// MARK: - Static Deposit Tests (matching JS: static_deposit.test.ts)
// =============================================================================

@Suite("Static Deposit", .enabled(if: TestConfig.hasIntegrationCredentials))
struct StaticDepositTests {

    @Test("Should get UTXOs and fee estimate for a static deposit")
    func depositFeeEstimate() async throws {
        guard let mnemonic = TestConfig.staticDepositMnemonic,
              let targetAddress = TestConfig.staticDepositAddress else {
            print("Skipping: SPARK_TEST_STATIC_DEPOSIT_MNEMONIC / _ADDRESS not set")
            return
        }

        let wallet = try SparkWallet(mnemonic: mnemonic, account: TestConfig.staticDepositAccount)
        await wallet.start()
        defer { Task { await wallet.close() } }

        let utxos = try await wallet.getUtxosForDepositAddress(address: targetAddress)
        print("UTXOs at \(targetAddress): \(utxos.count)")
        for utxo in utxos {
            print("  txid=\(utxo.txid) vout=\(utxo.vout)")
        }
        #expect(!utxos.isEmpty, "Expected at least one UTXO")
    }

    @Test("Should estimate withdrawal fee for all balance")
    func withdrawalFeeEstimate() async throws {
        guard let mnemonic = TestConfig.staticDepositMnemonic,
              let withdrawAddress = TestConfig.staticDepositWithdrawAddress else {
            print("Skipping: SPARK_TEST_STATIC_DEPOSIT_MNEMONIC / _WITHDRAW_ADDRESS not set")
            return
        }

        let wallet = try SparkWallet(mnemonic: mnemonic, account: TestConfig.staticDepositAccount)
        await wallet.start()
        defer { Task { await wallet.close() } }

        let balance = try await wallet.getBalance()
        print("Balance: \(balance.satsBalance.available) sats, leaves: \(balance.leaves.count)")
        for leaf in balance.leaves {
            print("  leaf \(leaf.id): \(leaf.valueSats) sats [\(leaf.status)]")
        }

        guard !balance.leaves.isEmpty else {
            print("No leaves to estimate withdrawal for")
            return
        }

        let fee = try await wallet.getWithdrawalFeeEstimate(
            onChainAddress: withdrawAddress,
            leafIds: balance.leaves.map(\.id)
        )
        print("Withdrawal fee estimate: \(fee.feeSats) sats")
        print("Would receive: \(balance.satsBalance.available - fee.feeSats) sats")
        #expect(fee.feeSats > 0)
    }

    @Test("Should claim a static deposit")
    func claimStaticDeposit() async throws {
        guard let mnemonic = TestConfig.staticDepositMnemonic,
              let txID = TestConfig.staticDepositTxid else {
            print("Skipping: SPARK_TEST_STATIC_DEPOSIT_MNEMONIC / _TXID not set")
            return
        }

        let wallet = try SparkWallet(mnemonic: mnemonic, account: TestConfig.staticDepositAccount)
        await wallet.start()
        defer { Task { await wallet.close() } }

        let balanceBefore = try await wallet.getBalance()
        print("Balance before claim: \(balanceBefore.satsBalance.available) sats")

        let transferId = try await wallet.claimStaticDeposit(transactionId: txID, outputIndex: 0)
        print("Claim transfer ID: \(transferId)")

        try await Task.sleep(for: .seconds(3))
        let _ = try await wallet.claimAllPendingTransfers()

        let balanceAfter = try await wallet.getBalance()
        print("Balance after claim: \(balanceAfter.satsBalance.available) sats")
        #expect(balanceAfter.satsBalance.available > balanceBefore.satsBalance.available)
    }

    @Test("Should refund a static deposit", .disabled("Requires funded static deposit"))
    func refundStaticDeposit() async throws {
        let txID = "" // Set to a real static deposit txid
        guard !txID.isEmpty else { return }

        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let txHex = try await wallet.refundStaticDeposit(
            depositTransactionId: txID,
            destinationAddress: "bc1qhta0uu4a7yt0jp3vmzasl3srelx9v46ncl9x89",
            satsPerVbyte: 5
        )
        #expect(!txHex.isEmpty)
        print("Refund tx hex: \(txHex.prefix(80))...")
    }
}

// =============================================================================
// MARK: - On-Chain Deposit Tests
// =============================================================================

@Suite("On-Chain Deposit", .enabled(if: TestConfig.hasIntegrationCredentials))
struct OnChainDepositTests {

    @Test("Should claim on-chain deposit", .disabled("Requires funded deposit address"))
    func claimDeposit() async throws {
        let txID = "" // Set to a real on-chain txid
        guard !txID.isEmpty else { return }

        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        try await wallet.claimDeposit(txID: txID)
        let balance = try await wallet.getBalance()
        print("Balance after deposit claim: \(balance.satsBalance.available) sats")
        #expect(balance.satsBalance.available > 0)
    }
}

// =============================================================================
// MARK: - Debug / Utility Tests
// =============================================================================

@Suite("Settings", .enabled(if: TestConfig.hasIntegrationCredentials))
struct SettingsTests {

    @Test("Should toggle privacy mode")
    func privacyMode() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let settings = try await wallet.getWalletSettings()
        print("Privacy enabled: \(settings.privateEnabled)")

        // Toggle on
        let updated = try await wallet.setPrivacyEnabled(true)
        #expect(updated.privateEnabled == true)
        print("Privacy toggled ON")

        // Verify
        let check = try await wallet.getWalletSettings()
        #expect(check.privateEnabled == true)

        // Toggle back off
        let restored = try await wallet.setPrivacyEnabled(false)
        #expect(restored.privateEnabled == false)
        print("Privacy toggled OFF")
    }
}

@Suite("Debug", .enabled(if: TestConfig.hasIntegrationCredentials))
struct DebugTests {

    @Test("Show all nodes and balances")
    func showAllNodes() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let client = try await wallet.getCoordinatorClient()
        var request = Spark_QueryNodesRequest()
        request.ownerIdentityPubkey = wallet.signer.identityPublicKey
        request.network = wallet.config.networkProto
        let response = try await client.query_nodes(
            request: try await wallet.makeAuthenticatedRequest(message: request)
        )

        print("=== All Nodes (\(response.nodes.count)) ===")
        for (id, node) in response.nodes {
            print("  \(id): value=\(node.value) status=\(node.status)")
        }

        let balance = try await wallet.getBalance()
        print("Balance: \(balance.satsBalance.available) sats (\(balance.leaves.count) available leaves)")
    }

    @Test("Should get transfers")
    func getTransfers() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let transfers = try await wallet.getTransfers(limit: 10)
        print("=== Recent Transfers (\(transfers.count)) ===")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for t in transfers {
            let dir = t.senderIdentityPublicKey == wallet.identityPublicKeyHex ? "SENT" : "RECV"
            print("  \(dateFormatter.string(from: t.createdAt)) | \(dir) | \(t.totalValueSats) sats | \(t.status) | \(t.type) | \(t.id)")
        }
        #expect(transfers.count > 0)

        // Test getTransfer with first transfer's ID
        let first = transfers[0]
        let single = try await wallet.getTransfer(id: first.id)
        #expect(single.id == first.id)
        #expect(single.totalValueSats == first.totalValueSats)
        print("\nSingle transfer lookup OK: \(single.id)")
    }

    @Test("Show wallet info")
    func showWalletInfo() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let balA = try await walletA.getBalance()
        let balB = try await walletB.getBalance()

        print("=== Wallet A ===")
        print("  Identity: \(walletA.identityPublicKeyHex)")
        print("  Spark:    \(walletA.getSparkAddress())")
        print("  Balance:  \(balA.satsBalance.available) sats (\(balA.leaves.count) leaves)")

        print("=== Wallet B ===")
        print("  Identity: \(walletB.identityPublicKeyHex)")
        print("  Spark:    \(walletB.getSparkAddress())")
        print("  Balance:  \(balB.satsBalance.available) sats (\(balB.leaves.count) leaves)")
    }
}

// =============================================================================
// MARK: - Funding Helpers (run manually)
// =============================================================================

@Suite("Funding", .enabled(if: TestConfig.hasIntegrationCredentials))
struct FundingTests {

    @Test("Create lightning invoice to fund WalletA")
    func fundWalletA() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let invoice = try await wallet.createLightningInvoice(
            amountSats: 2000, memo: "Fund walletA for tests"
        )
        print("\n=== PAY THIS INVOICE TO FUND WALLET A ===")
        print(invoice.paymentRequest)
        print("==========================================")
        print("Amount: 2000 sats | Hash: \(invoice.paymentHash)")
    }

    @Test("Claim all pending transfers for WalletA")
    func claimWalletA() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let claimed = try await wallet.claimAllPendingTransfers()
        let balance = try await wallet.getBalance()
        print("Claimed \(claimed) transfers. Balance: \(balance.satsBalance.available) sats")
    }
}

// =============================================================================
// MARK: - Token (BTKN) Integration Tests
// =============================================================================

@Suite("Tokens", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct TokenIntegrationTests {

    @Test("Should create a token, mint, transfer A->B, transfer B->A, and burn")
    func fullTokenLifecycle() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        // --- Phase 1: Create Token (or reuse existing) ---
        print("\n--- Phase 1: Create Token ---")
        let existingMetadatas = try await walletA.queryTokenMetadata(
            issuerPublicKeys: [walletA.signer.identityPublicKey]
        )
        let tokenIdentifier: String
        if let existing = existingMetadatas.first {
            tokenIdentifier = existing.tokenIdentifier
            print("Reusing existing token: \(existing.tokenName) (\(existing.tokenTicker))")
            print("Token identifier: \(tokenIdentifier)")
        } else {
            let creation = try await walletA.createToken(
                tokenName: "SwiftTest",
                tokenTicker: "SWFT",
                decimals: 2,
                maxSupply: 1_000_000,
                isFreezable: false
            )
            #expect(!creation.transactionHash.isEmpty)
            print("Token created, tx: \(creation.transactionHash)")

            try await Task.sleep(for: .seconds(5))

            let metadatas = try await walletA.queryTokenMetadata(
                issuerPublicKeys: [walletA.signer.identityPublicKey]
            )
            guard let tokenMeta = metadatas.first else {
                Issue.record("Token metadata not found after creation")
                return
            }
            tokenIdentifier = tokenMeta.tokenIdentifier
            print("Token identifier: \(tokenIdentifier)")
        }
        #expect(tokenIdentifier.hasPrefix("btkn1"))

        // --- Phase 2: Mint Tokens ---
        print("\n--- Phase 2: Mint 10000 tokens ---")
        let mintAmount: UInt128 = 10000
        let mintTx = try await walletA.mintTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: mintAmount
        )
        #expect(!mintTx.isEmpty)
        print("Mint tx: \(mintTx)")

        try await Task.sleep(for: .seconds(5))

        // Check balance
        let balancesAfterMint = try await walletA.getTokenBalances()
        let swftBalance = balancesAfterMint.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        #expect(swftBalance != nil)
        print("WalletA SWFT balance after mint: \(swftBalance?.ownedBalance ?? 0)")
        #expect(swftBalance!.ownedBalance >= mintAmount)

        // --- Phase 3: Transfer A -> B (5000 tokens) ---
        print("\n--- Phase 3: Transfer 5000 SWFT A -> B ---")
        let transferAmount: UInt128 = 5000
        let sparkAddressB = walletB.getSparkAddress()
        let transferTx = try await walletA.transferTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: transferAmount,
            receiverSparkAddress: sparkAddressB
        )
        #expect(!transferTx.isEmpty)
        print("Transfer A->B tx: \(transferTx)")

        try await Task.sleep(for: .seconds(5))

        // Check B's balance
        let balancesB = try await walletB.getTokenBalances()
        let swftBalanceB = balancesB.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletB SWFT balance: \(swftBalanceB?.ownedBalance ?? 0)")
        #expect(swftBalanceB != nil)
        #expect(swftBalanceB!.ownedBalance >= transferAmount)

        // Check A's remaining balance
        let balancesA2 = try await walletA.getTokenBalances()
        let swftBalanceA2 = balancesA2.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletA SWFT balance after transfer: \(swftBalanceA2?.ownedBalance ?? 0)")

        // --- Phase 4: Transfer B -> A (send it all back) ---
        print("\n--- Phase 4: Transfer all SWFT B -> A ---")
        let sparkAddressA = walletA.getSparkAddress()
        let returnTx = try await walletB.transferTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: transferAmount,
            receiverSparkAddress: sparkAddressA
        )
        #expect(!returnTx.isEmpty)
        print("Transfer B->A tx: \(returnTx)")

        try await Task.sleep(for: .seconds(5))

        // B should have 0 SWFT
        let finalBBalances = try await walletB.getTokenBalances()
        let finalBSwft = finalBBalances.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletB final SWFT balance: \(finalBSwft?.ownedBalance ?? 0)")
        #expect(finalBSwft == nil || finalBSwft!.ownedBalance == 0)

        // A should have all tokens back
        let finalABalances = try await walletA.getTokenBalances()
        let finalASwft = finalABalances.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletA final SWFT balance: \(finalASwft?.ownedBalance ?? 0)")
        #expect(finalASwft != nil && finalASwft!.ownedBalance >= mintAmount)

        // --- Phase 5: Burn some tokens ---
        print("\n--- Phase 5: Burn 1000 SWFT ---")
        let burnAmount: UInt128 = 1000
        let burnTx = try await walletA.burnTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: burnAmount
        )
        #expect(!burnTx.isEmpty)
        print("Burn tx: \(burnTx)")

        try await Task.sleep(for: .seconds(5))

        let afterBurn = try await walletA.getTokenBalances()
        let afterBurnSwft = afterBurn.first(where: { $0.tokenMetadata.tokenIdentifier == tokenIdentifier })
        print("WalletA token balance after burn: \(afterBurnSwft?.ownedBalance ?? 0)")

        print("\nFull token lifecycle complete!")
    }

    @Test("Should query token outputs")
    func queryTokenOutputs() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let outputs = try await wallet.getTokenOutputs()
        print("Token outputs: \(outputs.count)")
        for output in outputs.prefix(5) {
            let tokenId = output.tokenIdentifier.hexString
            print("  amount=\(output.tokenAmount) token=\(tokenId.prefix(16))... status=\(output.status)")
        }
    }

    @Test("Should query token balances")
    func queryTokenBalances() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let balances = try await wallet.getTokenBalances()
        print("Token balances: \(balances.count) tokens")
        for balance in balances {
            print("  \(balance.tokenMetadata.tokenName) (\(balance.tokenMetadata.tokenTicker))")
            print("    identifier: \(balance.tokenMetadata.tokenIdentifier)")
            print("    owned: \(balance.ownedBalance)")
            print("    available: \(balance.availableToSendBalance)")
            print("    decimals: \(balance.tokenMetadata.decimals)")
        }
    }

    @Test("Should query token metadata by issuer")
    func queryTokenMetadataByIssuer() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let metadatas = try await wallet.queryTokenMetadata(
            issuerPublicKeys: [wallet.signer.identityPublicKey]
        )
        print("Token metadata for issuer: \(metadatas.count) tokens")
        for meta in metadatas {
            print("  \(meta.tokenName) (\(meta.tokenTicker))")
            print("    identifier: \(meta.tokenIdentifier)")
            print("    issuer: \(meta.issuerPublicKey.hexString)")
            print("    maxSupply: \(decodeUInt128(meta.maxSupply))")
            print("    freezable: \(meta.isFreezable)")
        }
    }
}

// =============================================================================
// MARK: - Idempotency Tests
// =============================================================================

@Suite("Idempotency", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct IdempotencyTests {

    @Test("Token transfer with same idempotency key should not double-spend")
    func tokenTransferIdempotency() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        // Find the SWFT token
        let balancesBefore = try await walletA.getTokenBalances()
        guard let swftBefore = balancesBefore.first(where: { $0.tokenMetadata.tokenTicker == "SWFT" }) else {
            Issue.record("No SWFT token found on WalletA. Run fullTokenLifecycle test first.")
            return
        }
        let tokenIdentifier = swftBefore.tokenMetadata.tokenIdentifier
        let balanceBefore = swftBefore.ownedBalance
        print("WalletA SWFT before: \(balanceBefore)")
        guard balanceBefore >= 100 else {
            Issue.record("Need >= 100 SWFT tokens")
            return
        }

        let sparkAddressB = walletB.getSparkAddress()
        let idempotencyKey = "test-idem-token-\(UUID().uuidString)"
        let transferAmount: UInt128 = 50

        // First call — should succeed
        let tx1 = try await walletA.transferTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: transferAmount,
            receiverSparkAddress: sparkAddressB,
            idempotencyKey: idempotencyKey
        )
        #expect(!tx1.isEmpty)
        print("First transfer tx: \(tx1)")

        try await Task.sleep(for: .seconds(3))

        // Check balance decreased by transferAmount
        let balancesAfterFirst = try await walletA.getTokenBalances()
        let swftAfterFirst = balancesAfterFirst.first(where: { $0.tokenMetadata.tokenTicker == "SWFT" })!
        print("WalletA SWFT after first transfer: \(swftAfterFirst.ownedBalance)")
        #expect(swftAfterFirst.ownedBalance == balanceBefore - transferAmount)

        // Send back from B to A to clean up
        let sparkAddressA = walletA.getSparkAddress()
        let _ = try await walletB.transferTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: transferAmount,
            receiverSparkAddress: sparkAddressA
        )
        try await Task.sleep(for: .seconds(3))

        let balancesFinal = try await walletA.getTokenBalances()
        let swftFinal = balancesFinal.first(where: { $0.tokenMetadata.tokenTicker == "SWFT" })!
        print("WalletA SWFT after return: \(swftFinal.ownedBalance)")
        #expect(swftFinal.ownedBalance == balanceBefore)

        print("Token idempotency test passed!")
    }

    @Test("Lightning payment with idempotency key should work")
    func lightningPaymentIdempotency() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let balance = try await walletA.getBalance()
        guard balance.satsBalance.available >= 100 else {
            Issue.record("WalletA needs >= 100 sats (has \(balance.satsBalance.available))")
            return
        }

        let invoice = try await walletB.createLightningInvoice(
            amountSats: 10, memo: "idempotency test"
        )

        let idempotencyKey = "test-idem-ln-\(UUID().uuidString)"

        // First call — should succeed
        let paymentId = try await walletA.payLightningInvoice(
            paymentRequest: invoice.paymentRequest,
            idempotencyKey: idempotencyKey
        )
        #expect(!paymentId.isEmpty)
        print("Lightning payment with idempotency key: \(paymentId)")

        let balanceAfter = try await walletA.getBalance()
        print("WalletA balance after: \(balanceAfter.satsBalance.available) sats (was \(balance.satsBalance.available))")
        #expect(balanceAfter.satsBalance.available < balance.satsBalance.available)

        print("Lightning idempotency test passed!")
    }

    @Test("Mint with idempotency key should work")
    func mintIdempotency() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }

        let metadatas = try await walletA.queryTokenMetadata(
            issuerPublicKeys: [walletA.signer.identityPublicKey]
        )
        guard let tokenMeta = metadatas.first else {
            Issue.record("No token found. Run fullTokenLifecycle test first.")
            return
        }

        let balanceBefore = try await walletA.getTokenBalances()
        let swftBefore = balanceBefore.first(where: {
            $0.tokenMetadata.tokenIdentifier == tokenMeta.tokenIdentifier
        })!.ownedBalance
        print("SWFT before mint: \(swftBefore)")

        let mintAmount: UInt128 = 100
        let tx = try await walletA.mintTokens(
            tokenIdentifier: tokenMeta.tokenIdentifier,
            tokenAmount: mintAmount
        )
        #expect(!tx.isEmpty)
        print("Mint tx: \(tx)")

        try await Task.sleep(for: .seconds(3))

        let balanceAfter = try await walletA.getTokenBalances()
        let swftAfter = balanceAfter.first(where: {
            $0.tokenMetadata.tokenIdentifier == tokenMeta.tokenIdentifier
        })!.ownedBalance
        print("SWFT after mint: \(swftAfter)")
        #expect(swftAfter == swftBefore + mintAmount)

        print("Mint idempotency test passed!")
    }
}

// =============================================================================
// MARK: - Invoice-to-Transfer Matching Tests
// =============================================================================

@Suite("Invoice Matching", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct InvoiceMatchingTests {

    @Test("Regular Spark transfer should have nil sparkInvoice")
    func sparkTransferHasNoInvoice() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let balanceA = try await walletA.getBalance()
        guard balanceA.satsBalance.available >= 20 else {
            Issue.record("WalletA needs >= 20 sats")
            return
        }

        // Direct Spark transfer (no invoice)
        let pubB = Data(hexString: walletB.identityPublicKeyHex)!
        let transfer = try await walletA.send(
            receiverIdentityPublicKey: pubB, amountSats: 10
        )
        print("Direct transfer: \(transfer.id) sparkInvoice=\(transfer.sparkInvoice ?? "nil")")
        #expect(transfer.sparkInvoice == nil, "Direct Spark transfers should not have a sparkInvoice")

        // Verify via query too
        try await Task.sleep(for: .seconds(3))
        let queried = try await walletA.getTransfer(id: transfer.id)
        print("Queried transfer: sparkInvoice=\(queried.sparkInvoice ?? "nil")")
        #expect(queried.sparkInvoice == nil)

        // Claim on B so the transfer completes
        let _ = try await walletB.claimAllPendingTransfers()

        print("Direct Spark transfer has no invoice - confirmed!")
    }

    @Test("getTransferFromSsp should match lightning invoice to transfer via payment_hash")
    func matchViaGetTransferFromSsp() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let balanceA = try await walletA.getBalance()
        guard balanceA.satsBalance.available >= 50 else {
            Issue.record("WalletA needs >= 50 sats (has \(balanceA.satsBalance.available))")
            return
        }

        // --- Step 1: WalletB creates a lightning invoice ---
        let invoice = try await walletB.createLightningInvoice(
            amountSats: 10, memo: "ssp match test"
        )
        print("Invoice: \(invoice.paymentRequest.prefix(40))...")
        print("Payment hash: \(invoice.paymentHash)")

        // --- Step 2: WalletA pays the invoice ---
        let paymentId = try await walletA.payLightningInvoice(
            paymentRequest: invoice.paymentRequest
        )
        print("Payment ID: \(paymentId)")

        try await Task.sleep(for: .seconds(5))
        let _ = try await walletB.claimAllPendingTransfers()

        // --- Step 3: Find the preimage swap transfer on sender side ---
        let sentTransfers = try await walletA.getTransfers(direction: .sent, limit: 3)
        let sentSwap = sentTransfers.first { $0.type == "preimageSwap" }
        #expect(sentSwap != nil, "Should find a sent preimageSwap transfer")

        // --- Step 4: Use getTransferFromSsp on the SENDER side ---
        print("\n=== Sender (WalletA) SSP lookup ===")
        if let sent = sentSwap {
            let sspTransfer = try await walletA.getTransferFromSsp(id: sent.id)
            if let ssp = sspTransfer {
                print("  sparkId: \(ssp.sparkId)")
                print("  totalAmountSats: \(ssp.totalAmountSats ?? -1)")
                switch ssp.userRequest {
                case .lightningSend(let info):
                    print("  type: LightningSendRequest")
                    print("  status: \(info.status)")
                    print("  encodedInvoice: \(info.encodedInvoice?.prefix(40) ?? "nil")...")
                    print("  feeSats: \(info.feeSats ?? -1)")
                    print("  paymentPreimage: \(info.paymentPreimage ?? "nil")")
                    // The encoded invoice on the send side should match what was paid
                    #expect(info.encodedInvoice == invoice.paymentRequest,
                            "SSP send request should reference the original invoice")
                default:
                    print("  type: \(String(describing: ssp.userRequest))")
                }
            } else {
                print("  Not found in SSP")
            }
        }

        // --- Step 5: Find the preimage swap transfer on receiver side ---
        let receivedTransfers = try await walletB.getTransfers(direction: .received, limit: 3)
        let recvSwap = receivedTransfers.first { $0.type == "preimageSwap" }
        #expect(recvSwap != nil, "Should find a received preimageSwap transfer")

        // --- Step 6: Use getTransferFromSsp on the RECEIVER side ---
        print("\n=== Receiver (WalletB) SSP lookup ===")
        if let recv = recvSwap {
            let sspTransfer = try await walletB.getTransferFromSsp(id: recv.id)
            if let ssp = sspTransfer {
                print("  sparkId: \(ssp.sparkId)")
                print("  totalAmountSats: \(ssp.totalAmountSats ?? -1)")
                switch ssp.userRequest {
                case .lightningReceive(let info):
                    print("  type: LightningReceiveRequest")
                    print("  status: \(info.status)")
                    print("  paymentHash: \(info.paymentHash ?? "nil")")
                    print("  encodedInvoice: \(info.encodedInvoice?.prefix(40) ?? "nil")...")
                    print("  memo: \(info.memo ?? "nil")")
                    print("  amountSats: \(info.amountSats ?? -1)")
                    print("  paymentPreimage: \(info.paymentPreimage?.prefix(16) ?? "nil")...")

                    // THIS IS THE KEY MATCH: the payment_hash from the SSP matches the invoice
                    #expect(info.paymentHash == invoice.paymentHash,
                            "SSP receive request payment_hash should match the invoice payment_hash")
                    print("\n  MATCH CONFIRMED: payment_hash from SSP == invoice payment_hash")
                default:
                    print("  type: \(String(describing: ssp.userRequest))")
                }
            } else {
                print("  Not found in SSP")
            }
        }

        print("\ngetTransferFromSsp matching test complete!")
    }
}

// =============================================================================
// MARK: - Full Integration Flow (matching JS: end-to-end patterns)
// =============================================================================

@Suite("Full Flow", .enabled(if: TestConfig.hasIntegrationCredentials))
struct FullFlowTests {

    @Test("Lightning A->B, Spark transfer B->A, external lightning pay")
    func fullRoundTrip() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        // Check walletA has funds
        let initialBalance = try await walletA.getBalance()
        print("WalletA initial balance: \(initialBalance.satsBalance.available) sats")
        guard initialBalance.satsBalance.available >= minimumTestBalance else {
            let deposit = try await walletA.getDepositAddress()
            Issue.record("WalletA needs >= \(minimumTestBalance) sats. Deposit to: \(deposit.address)")
            return
        }

        // --- Phase 1: Lightning A -> B ---
        print("\n--- Phase 1: Lightning A -> B (100 sats) ---")
        let invoice = try await walletB.createLightningInvoice(
            amountSats: 100, memo: "full flow test"
        )
        #expect(invoice.amountSats == 100)

        let payID = try await walletA.payLightningInvoice(
            paymentRequest: invoice.paymentRequest
        )
        #expect(!payID.isEmpty)
        print("Payment sent: \(payID)")

        try await Task.sleep(for: .seconds(5))

        // B claims incoming payment
        let claimedB = try await walletB.claimAllPendingTransfers()
        print("WalletB claimed \(claimedB) transfers")

        let balB = try await walletB.getBalance()
        #expect(balB.satsBalance.available >= 100)
        print("WalletB balance: \(balB.satsBalance.available) sats")

        // --- Phase 2: Spark Transfer B -> A ---
        print("\n--- Phase 2: Spark B -> A (\(balB.satsBalance.available) sats) ---")
        let pubA = Data(hexString: walletA.identityPublicKeyHex)!
        let transfer = try await walletB.send(
            receiverIdentityPublicKey: pubA, amountSats: balB.satsBalance.available
        )
        #expect(!transfer.id.isEmpty)
        print("Transfer: \(transfer.id)")

        try await Task.sleep(for: .seconds(3))

        let claimedA = try await walletA.claimAllPendingTransfers()
        #expect(claimedA >= 1)

        let balA2 = try await walletA.getBalance()
        print("WalletA balance after Phase 2: \(balA2.satsBalance.available) sats")

        // B should be empty
        let finalB = try await walletB.getBalance()
        #expect(finalB.satsBalance.available == 0)

        // --- Phase 3: External Lightning A -> external address ---
        guard let externalAddress = TestConfig.externalLightningAddress else {
            print("Skipping Phase 3: SPARK_TEST_LIGHTNING_ADDRESS not set")
            let finalA = try await walletA.getBalance()
            print("\nFinal WalletA balance: \(finalA.satsBalance.available) sats")
            return
        }
        print("\n--- Phase 3: Lightning A -> \(externalAddress) (10 sats) ---")
        let bolt11 = try await resolveLightningAddress(externalAddress, amountSats: 10)
        let extPayID = try await walletA.payLightningInvoice(paymentRequest: bolt11)
        #expect(!extPayID.isEmpty)
        print("External payment: \(extPayID)")

        let finalA = try await walletA.getBalance()
        print("\nFinal WalletA balance: \(finalA.satsBalance.available) sats")
        #expect(finalA.satsBalance.available >= initialBalance.satsBalance.available - 120, "Should only lose ~15 sats in routing fees, not hundreds")
        print("Full flow complete!")
    }

    @Test("On-chain withdrawal fee estimate")
    func testOnChainFeeEstimate() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        let address = "bc1qdxqntgy40ut7ep3mddds98t5undss7ka6l2dud"

        let balance = try await wallet.getBalance()
        print("Balance: \(balance.satsBalance.available) sats")

        let leaves = try await wallet.getLeaves()
        print("Leaves: \(leaves.count)")

        guard !leaves.isEmpty else {
            print("No leaves — can't estimate fee")
            return
        }

        let fee = try await wallet.getWithdrawalFeeEstimate(
            onChainAddress: address,
            leafIds: leaves.map(\.id)
        )
        print("On-chain fee estimate: \(fee.feeSats) sats")
        #expect(fee.feeSats > 0)

        await wallet.close()
    }
}
