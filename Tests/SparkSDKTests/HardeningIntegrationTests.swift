import Foundation
import Testing
@testable import SparkSDK

/// Mainnet checks for the hardening changes: exact-amount Spark transfers to a Spark address,
/// fee-capped lightning payments against verified invoices, claim-side signature verification,
/// and argument validation that must fail before any leaf is touched. Whichever test wallet can
/// spend more (leaves above the timelock floor) acts as the sender, so the suite works no matter
/// which wallet was last funded.
///
/// The on-chain withdrawal test is opt-in (`SPARK_TEST_ALLOW_WITHDRAW=1`): it sends real sats to
/// `SPARK_TEST_STATIC_DEPOSIT_WITHDRAW_ADDRESS` and pays a coop-exit fee.
@Suite("Hardening", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct HardeningIntegrationTests {

    struct Pair {
        let sender: SparkWallet
        let receiver: SparkWallet
        let senderLabel: String
        let senderSpendable: Int64
    }

    /// Sats the wallet can send right now (renews what the coordinator will renew, skips frozen leaves).
    static func spendable(_ wallet: SparkWallet) async throws -> Int64 {
        let leaves = try await wallet.getSpendableLeaves()
        let allSpendable = leaves.allSatisfy(\.isSpendable)
        #expect(allSpendable)
        return leaves.reduce(0) { $0 + $1.valueSats }
    }

    static func makePair() async throws -> Pair {
        let a = try await makeWallet(TestConfig.walletAMnemonic)
        let b = try await makeWallet(TestConfig.walletBMnemonic)
        let spendableA = try await spendable(a)
        let spendableB = try await spendable(b)
        if spendableA >= spendableB {
            return Pair(sender: a, receiver: b, senderLabel: "A", senderSpendable: spendableA)
        }
        return Pair(sender: b, receiver: a, senderLabel: "B", senderSpendable: spendableB)
    }

    @Test("Spark transfer to a Spark address is claimed after sender-signature verification", .timeLimit(.minutes(5)))
    func sparkTransferRoundTrip() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let amount: Int64 = 10
        guard pair.senderSpendable >= amount + 5 else {
            Issue.record(Comment(rawValue: "neither wallet has \(amount + 5) spendable sats (best: \(pair.senderSpendable))"))
            return
        }
        let receiverBefore = try await pair.receiver.getBalance()
        let senderBefore = try await pair.sender.getBalance()

        let transfer = try await pair.sender.send(
            receiverSparkAddress: pair.receiver.getSparkAddress(), amountSats: amount
        )
        #expect(!transfer.id.isEmpty)
        #expect(transfer.totalValueSats == amount)
        #expect(transfer.receiverIdentityPublicKey == pair.receiver.identityPublicKeyHex)
        print("[\(pair.senderLabel)] sent \(amount) sats, transfer \(transfer.id)")

        try await Task.sleep(for: .seconds(3))
        let claimed = try await pair.receiver.claimAllPendingTransfers()
        #expect(claimed >= 1)

        let receiverAfter = try await pair.receiver.getBalance()
        let senderAfter = try await pair.sender.getBalance()
        #expect(receiverAfter.satsBalance.owned == receiverBefore.satsBalance.owned + receiverBefore.satsBalance.incoming + amount)
        #expect(senderAfter.satsBalance.owned == senderBefore.satsBalance.owned - amount)
        print("receiver \(receiverBefore.satsBalance.owned) -> \(receiverAfter.satsBalance.owned), sender \(senderBefore.satsBalance.owned) -> \(senderAfter.satsBalance.owned)")
    }

    @Test("Lightning payment of a verified invoice under a fee cap, then claim", .timeLimit(.minutes(5)))
    func lightningRoundTrip() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let amount: Int64 = 10
        let invoice = try await pair.receiver.createLightningInvoice(amountSats: amount, memo: "hardening test")
        #expect(invoice.amountSats == amount)
        let decoded = try Bolt11Invoice.decode(invoice.paymentRequest)
        #expect(decoded.paymentHash.hexString == invoice.paymentHash)
        #expect(decoded.amountMsat == UInt64(amount) * 1000)
        #expect(decoded.network == .mainnet)

        let fee = try await pair.sender.getLightningSendFeeEstimate(encodedInvoice: invoice.paymentRequest)
        print("[\(pair.senderLabel)] fee estimate \(fee) sats for \(amount) sats")
        guard pair.senderSpendable >= amount + max(fee, 1) + 5 else {
            Issue.record(Comment(rawValue: "sender needs \(amount + max(fee, 1) + 5) spendable sats, has \(pair.senderSpendable)"))
            return
        }
        let receiverBefore = try await pair.receiver.getBalance()
        let senderBefore = try await pair.sender.getBalance()

        let requestId = try await pair.sender.payLightningInvoice(
            paymentRequest: invoice.paymentRequest, maxFeeSats: max(fee, 1) + 5
        )
        #expect(!requestId.isEmpty)
        print("lightning send request \(requestId)")

        try await Task.sleep(for: .seconds(5))
        let claimed = try await pair.receiver.claimAllPendingTransfers()
        print("receiver claimed \(claimed) transfer(s)")

        let receiverAfter = try await pair.receiver.getBalance()
        let senderAfter = try await pair.sender.getBalance()
        #expect(receiverAfter.satsBalance.owned >= receiverBefore.satsBalance.owned + amount)
        #expect(senderAfter.satsBalance.owned <= senderBefore.satsBalance.owned - amount)
        #expect(senderAfter.satsBalance.owned >= senderBefore.satsBalance.owned - amount - max(fee, 1) - 5)
        print("receiver \(receiverBefore.satsBalance.owned) -> \(receiverAfter.satsBalance.owned), sender \(senderBefore.satsBalance.owned) -> \(senderAfter.satsBalance.owned)")
    }

    @Test("A fee cap below the SSP estimate is refused before any leaf is locked", .timeLimit(.minutes(3)))
    func feeCapRefusal() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let invoice = try await pair.receiver.createLightningInvoice(amountSats: 10, memo: "fee cap test")
        let fee = try await pair.sender.getLightningSendFeeEstimate(encodedInvoice: invoice.paymentRequest)
        let before = try await pair.sender.getBalance()
        // The SDK never sends a fee below 1 sat, so a cap of 0 must always be refused.
        do {
            _ = try await pair.sender.payLightningInvoice(paymentRequest: invoice.paymentRequest, maxFeeSats: 0)
            Issue.record(Comment(rawValue: "payment went through with a zero fee cap (estimate \(fee))"))
        } catch SparkError.feeExceedsLimit(let quoted, let cap) {
            #expect(cap == 0)
            #expect(quoted >= 1)
        }
        let after = try await pair.sender.getBalance()
        #expect(after.satsBalance.owned == before.satsBalance.owned)
        #expect(after.satsBalance.available == before.satsBalance.available)
    }

    @Test("Bad arguments are rejected before any network call moves a leaf", .timeLimit(.minutes(3)))
    func argumentValidation() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let before = try await pair.sender.getBalance()
        let address = pair.receiver.getSparkAddress()

        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: address, amountSats: 0) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: address, amountSats: -1) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: "sparkrt1qq", amountSats: 1) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: address, amountSats: 1_000_000_000) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.withdraw(onChainAddress: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", amountSats: 0) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.withdraw(onChainAddress: "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", amountSats: 1_000) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.withdraw(onChainAddress: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", amountSats: 1_000_000_000) }
        await #expect(throws: SparkError.self) {
            _ = try await pair.sender.payLightningInvoice(paymentRequest: "lntb20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygshp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk98klysy043l2ahrqspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqfpp3x9et2e20v6pu37c5d9vax37wxq72un989qrsgqdj545axuxtnfemtpwkc45hx9d2ft7x04mt8q7y6t0k2dge9e7h8kpy9p34ytyslj3yu569aalz2xdk8xkd7ltxqld94u8h2esmsmacgpghe9k8", maxFeeSats: 10)
        }
        let after = try await pair.sender.getBalance()
        #expect(after.satsBalance.owned == before.satsBalance.owned)
        #expect(after.satsBalance.available == before.satsBalance.available)
    }

    /// Destination: `SPARK_TEST_WITHDRAW_DESTINATION` may be an address, or
    /// `receiver-static-deposit` to pay the other test wallet's static deposit address so the
    /// sats stay inside the test setup and can be claimed back with `claimStaticDeposit`.
    /// Falls back to `SPARK_TEST_STATIC_DEPOSIT_WITHDRAW_ADDRESS`.
    @Test("Small on-chain withdrawal with a verified payout", .timeLimit(.minutes(10)),
          .enabled(if: ProcessInfo.processInfo.environment["SPARK_TEST_ALLOW_WITHDRAW"] == "1"))
    func withdrawal() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let destination: String
        switch ProcessInfo.processInfo.environment["SPARK_TEST_WITHDRAW_DESTINATION"] {
        case "receiver-static-deposit"?:
            destination = try await pair.receiver.getStaticDepositAddress().address
            print("destination: static deposit address of the receiver wallet \(destination)")
        case let explicit? where !explicit.isEmpty:
            destination = explicit
        default:
            guard let configured = TestConfig.staticDepositWithdrawAddress else {
                Issue.record(Comment(rawValue: "no withdrawal destination configured"))
                return
            }
            destination = configured
        }
        let amount: Int64 = Int64(ProcessInfo.processInfo.environment["SPARK_TEST_WITHDRAW_SATS"] ?? "") ?? 3_000
        let maxFee: Int64 = Int64(ProcessInfo.processInfo.environment["SPARK_TEST_WITHDRAW_MAX_FEE_SATS"] ?? "") ?? 2_500
        guard pair.senderSpendable >= amount else {
            Issue.record(Comment(rawValue: "sender needs \(amount) spendable sats, has \(pair.senderSpendable)"))
            return
        }
        let before = try await pair.sender.getBalance()
        let txid = try await pair.sender.withdraw(onChainAddress: destination, amountSats: amount, maxFeeSats: maxFee)
        #expect(txid.count == 64)
        print("[\(pair.senderLabel)] withdrew \(amount) sats (fee cap \(maxFee)) to \(destination): txid \(txid)")
        try await Task.sleep(for: .seconds(3))
        // The exited leaves stay transfer-locked (still owned) until the exit transaction confirms
        // on-chain; only the spendable balance drops immediately.
        let after = try await pair.sender.getBalance()
        #expect(after.satsBalance.available == before.satsBalance.available - amount)
        #expect(after.satsBalance.owned >= before.satsBalance.owned - amount)
        #expect(after.satsBalance.owned <= before.satsBalance.owned)
    }

    /// Drains the sender wallet with `withdrawAll`. Opt-in (`SPARK_TEST_ALLOW_WITHDRAW_ALL=1`); the
    /// destination follows `SPARK_TEST_WITHDRAW_DESTINATION` like the partial withdrawal test.
    @Test("withdrawAll drains every spendable sat with a verified payout and reports what stays", .timeLimit(.minutes(10)),
          .enabled(if: ProcessInfo.processInfo.environment["SPARK_TEST_ALLOW_WITHDRAW_ALL"] == "1"))
    func withdrawAll() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let destination: String
        switch ProcessInfo.processInfo.environment["SPARK_TEST_WITHDRAW_DESTINATION"] {
        case "receiver-static-deposit"?:
            destination = try await pair.receiver.getStaticDepositAddress().address
        case let explicit? where !explicit.isEmpty:
            destination = explicit
        default:
            guard let configured = TestConfig.staticDepositWithdrawAddress else {
                Issue.record(Comment(rawValue: "no withdrawal destination configured"))
                return
            }
            destination = configured
        }

        let quote = try await pair.sender.quoteWithdrawAll(onChainAddress: destination)
        print("[\(pair.senderLabel)] quote: spendable \(quote.spendableSats) fee \(quote.quotedFeeSats) payout≈\(quote.estimatedPayoutSats) frozen \(quote.frozenSats) (\(Int(quote.frozenFraction * 1000) / 10)%) locked \(quote.lockedSats) incoming \(quote.incomingSats) leaves \(quote.leafCount)")
        #expect(quote.spendableSats == pair.senderSpendable)
        guard quote.coversFee else {
            Issue.record(Comment(rawValue: "fee \(quote.quotedFeeSats) not covered by \(quote.spendableSats) spendable sats"))
            return
        }

        let result = try await pair.sender.withdrawAll(onChainAddress: destination)
        print("[\(pair.senderLabel)] withdrawAll: txid \(result.txid) sent \(result.sentSats) payout \(result.payoutSats) fee \(result.feeSats) frozen \(result.frozenSats) locked \(result.lockedSats) unclaimed \(result.unclaimedSats)")
        #expect(result.txid.count == 64)
        #expect(result.sentSats == quote.spendableSats)
        #expect(result.payoutSats >= quote.spendableSats - quote.quotedFeeSats)
        #expect(result.payoutSats < result.sentSats)
        #expect(result.frozenSats == quote.frozenSats)

        try await Task.sleep(for: .seconds(3))
        let after = try await pair.sender.getBalance().satsBalance
        #expect(after.available == 0)
        #expect(after.frozen == result.frozenSats)
        #expect(after.owned >= result.frozenSats)
    }

    /// Claims confirmed UTXOs sitting at a wallet's static deposit address back into Spark.
    /// Opt-in (`SPARK_TEST_CLAIM_STATIC=A|B`) because the SSP charges a fee for the claim.
    @Test("Claim confirmed static deposits back into the wallet", .timeLimit(.minutes(10)),
          .enabled(if: ["A", "B"].contains(ProcessInfo.processInfo.environment["SPARK_TEST_CLAIM_STATIC"] ?? "")))
    func claimStaticDeposits() async throws {
        let which = ProcessInfo.processInfo.environment["SPARK_TEST_CLAIM_STATIC"] ?? "B"
        let wallet = try await makeWallet(which == "A" ? TestConfig.walletAMnemonic : TestConfig.walletBMnemonic)
        defer { Task { await wallet.close() } }
        let address = try await wallet.getStaticDepositAddress().address
        var utxos = try await wallet.getUtxosForDepositAddress(address: address, excludeClaimed: true)
        print("[\(which)] static deposit address \(address): \(utxos.count) unclaimed utxo(s)")
        // SPARK_TEST_CLAIM_STATIC_TXID=<txid>:<vout> names a deposit the operators have not
        // indexed yet, so the SSP quote can be tried directly.
        if utxos.isEmpty, let explicit = ProcessInfo.processInfo.environment["SPARK_TEST_CLAIM_STATIC_TXID"] {
            let parts = explicit.split(separator: ":")
            if parts.count == 2, let vout = UInt32(parts[1]) {
                utxos = [DepositUtxo(txid: String(parts[0]), vout: vout)]
                print("  using explicit utxo \(explicit)")
            }
        }
        guard !utxos.isEmpty else {
            Issue.record(Comment(rawValue: "no unclaimed utxo at \(address) yet (unconfirmed, or already claimed)"))
            return
        }
        let before = try await wallet.getBalance()
        for utxo in utxos {
            let quote = try await wallet.getDepositFeeEstimate(transactionId: utxo.txid, outputIndex: utxo.vout)
            print("  \(utxo.txid):\(utxo.vout) credits \(quote.creditAmountSats) sats after the SSP fee")
            let transferId = try await wallet.claimStaticDeposit(transactionId: utxo.txid, outputIndex: utxo.vout)
            #expect(!transferId.isEmpty)
            print("  claim transfer \(transferId)")
        }
        try await Task.sleep(for: .seconds(5))
        let claimed = try await wallet.claimAllPendingTransfers()
        let after = try await wallet.getBalance()
        print("  claimed \(claimed) transfer(s); balance \(before.satsBalance.owned) -> \(after.satsBalance.owned)")
        #expect(after.satsBalance.owned > before.satsBalance.owned)
    }
}
