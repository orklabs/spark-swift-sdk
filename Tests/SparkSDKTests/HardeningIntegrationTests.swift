// swiftlint:disable line_length — carries a BOLT-11 specification vector
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

    @Test("Bad arguments are rejected before any network call moves a leaf", .timeLimit(.minutes(3)))
    func argumentValidation() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let before = try await pair.sender.getBalance()
        let address = pair.receiver.getSparkAddress()

        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: address, amountSats: 0) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: address, amountSats: -1) }
        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: "sparkrt1qq", amountSats: 1) }
        let invoice = try SparkInvoiceTests.satsInvoice(identityPublicKey: pair.receiver.signer.identityPublicKey, amountSats: 10, network: .mainnet)
        await #expect(throws: SparkError.self) { _ = try await pair.sender.send(receiverSparkAddress: invoice, amountSats: 10) }
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

    @Test("One claim pass takes every pending transfer and reports no failures", .timeLimit(.minutes(5)))
    func claimPassTakesEverything() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let amounts: [Int64] = [1, 2, 8]
        guard pair.senderSpendable >= amounts.reduce(0, +) + 5 else {
            Issue.record(Comment(rawValue: "sender needs \(amounts.reduce(0, +) + 5) spendable sats, has \(pair.senderSpendable)"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        var sent: [String] = []
        for amount in amounts {
            let transfer = try await pair.sender.send(receiverSparkAddress: pair.receiver.getSparkAddress(), amountSats: amount)
            sent.append(transfer.id)
        }
        try await Task.sleep(for: .seconds(3))

        let result = try await pair.receiver.claimPendingTransfers()
        print("[\(pair.senderLabel)] sent \(sent), receiver claimed \(result.claimedTransferIds), failures \(result.failures.map(\.transferId))")
        #expect(Set(sent).isSubset(of: Set(result.claimedTransferIds)))
        #expect(result.failures.isEmpty)
        #expect(!(try await pair.receiver.queryPendingTransfers().contains { sent.contains($0.id) }))
    }

    @Test("Claiming a transfer this wallet already claimed counts as claimed", .timeLimit(.minutes(5)))
    func claimingTwiceIsIdempotent() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        guard pair.senderSpendable >= 6 else {
            Issue.record(Comment(rawValue: "sender needs 6 spendable sats, has \(pair.senderSpendable)"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        let sent = try await pair.sender.send(receiverSparkAddress: pair.receiver.getSparkAddress(), amountSats: 1)
        try await Task.sleep(for: .seconds(3))
        let pending = try #require(try await pair.receiver.queryPendingTransfers().first { $0.id == sent.id })

        try await pair.receiver.claimTransfer(pending)
        // The operators now answer ALREADY_EXISTS; the reference SDK treats a completed transfer
        // as claimed, and so must we (a swap and a claim pass can race for the same transfer).
        try await pair.receiver.claimTransfer(pending)
        #expect(try await pair.receiver.queryTransferById(sent.id).status == .completed)
    }

    @Test("A send no leaf combination can pay exactly swaps for change first", .timeLimit(.minutes(5)))
    func sendWithSwap() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let leaves = try await pair.sender.getSpendableLeaves()
        let total = leaves.reduce(0) { $0 + $1.valueSats }
        guard let amount = (1...min(total, 200)).first(where: { SparkWallet.tryExactSelection(leaves, amountSats: $0) == nil }) else {
            Issue.record(Comment(rawValue: "every amount up to 200 sats has an exact leaf combination"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        let receiverBefore = try await pair.receiver.getBalance().satsBalance
        let transfer = try await pair.sender.send(receiverSparkAddress: pair.receiver.getSparkAddress(), amountSats: amount)
        print("[\(pair.senderLabel)] sent \(amount) sats through a swap, transfer \(transfer.id)")
        #expect(transfer.totalValueSats == amount)
        try await Task.sleep(for: .seconds(3))
        let claim = try await pair.receiver.claimPendingTransfers()
        #expect(claim.claimedTransferIds.contains(transfer.id))
        let receiverAfter = try await pair.receiver.getBalance().satsBalance
        #expect(receiverAfter.owned == receiverBefore.owned + receiverBefore.incoming + amount)
    }

    @Test("Sent sats leave owned once the transfer is committed, before the receiver claims", .timeLimit(.minutes(5)))
    func committedTransferLeavesOwned() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        guard pair.senderSpendable >= 6 else {
            Issue.record(Comment(rawValue: "sender needs 6 spendable sats, has \(pair.senderSpendable)"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        let before = try await pair.sender.getBalance().satsBalance
        let receiverBefore = try await pair.receiver.getBalance().satsBalance
        #expect(before.locked == 0)
        let transfer = try await pair.sender.send(receiverSparkAddress: pair.receiver.getSparkAddress(), amountSats: 1)
        #expect(transfer.status == "senderKeyTweaked")

        // The operators applied the sender's key tweak: the sat belongs to the receiver now, even
        // though its leaf stays TRANSFER_LOCKED under the sender's key until the claim.
        let sent = try await pair.sender.getBalance().satsBalance
        print("[\(pair.senderLabel)] owned \(before.owned) -> \(sent.owned), locked \(before.locked) -> \(sent.locked)")
        #expect(sent.owned == before.owned - 1)
        #expect(sent.locked == 0)
        let receiverPending = try await pair.receiver.getBalance().satsBalance
        #expect(receiverPending.incoming == receiverBefore.incoming + 1)
        #expect(receiverPending.owned == receiverBefore.owned)
        _ = try await pair.receiver.claimPendingTransfers()
    }

    @Test("Frozen sats are exactly the leaves below the renewal minimum, and the drain quote agrees", .timeLimit(.minutes(5)))
    func frozenClassification() async throws {
        let a = try await makeWallet(TestConfig.walletAMnemonic)
        let b = try await makeWallet(TestConfig.walletBMnemonic)
        defer { Task { await a.close(); await b.close() } }
        for (label, wallet, other) in [("A", a, b), ("B", b, a)] {
            let balance = try await wallet.getBalance()
            let frozenLeaves = balance.leaves.filter(\.isFrozen)
            let sum: ([SparkLeaf]) -> Int64 = { $0.reduce(0) { $0 + $1.valueSats } }
            #expect(balance.satsBalance.frozen == sum(frozenLeaves), "\(label)")
            #expect(balance.satsBalance.available == sum(balance.leaves.filter { !$0.isFrozen }), "\(label)")
            #expect(frozenLeaves.allSatisfy { $0.refundTimelockBlocks < sparkTimeLockInterval }, "\(label)")

            // The quote claims, renews what the operators will renew, and fetches a fee quote;
            // nothing leaves the wallet.
            let destination = try await other.getStaticDepositAddress().address
            let quote = try await wallet.quoteWithdrawAll(onChainAddress: destination)
            let after = try await wallet.getBalance().satsBalance
            print("[\(label)] available \(balance.satsBalance.available) frozen \(balance.satsBalance.frozen) -> quote spendable "
                  + "\(quote.spendableSats) frozen \(quote.frozenSats) unrenewed \(quote.unrenewedSats) locked \(quote.lockedSats)")
            #expect(quote.frozenSats == after.frozen, "\(label)")
            #expect(quote.unrenewedSats == 0, "\(label): every renewable leaf should have been renewed")
            #expect(quote.spendableSats + quote.unrenewedSats == after.available, "\(label)")
        }
    }

    /// Bounces one small leaf between the test wallets until a transfer delivers it in the renewal
    /// range (each Spark transfer takes 100 blocks off it); the receiver's claim pass must renew
    /// it to a fresh timelock right away. Opt-in (`SPARK_TEST_RENEWAL=1`) because it takes one
    /// transfer per 100 blocks of timelock.
    @Test("A leaf that arrives in the renewal range is renewed by the claim", .timeLimit(.minutes(20)),
          .enabled(if: ProcessInfo.processInfo.environment["SPARK_TEST_RENEWAL"] == "1"))
    func renewalRoundTrip() async throws {
        let a = try await makeWallet(TestConfig.walletAMnemonic)
        let b = try await makeWallet(TestConfig.walletBMnemonic)
        defer { Task { await a.close(); await b.close() } }
        struct Candidate {
            let holder: SparkWallet
            let other: SparkWallet
            let leaf: SparkLeaf
        }
        var candidates: [Candidate] = []
        for (holder, other) in [(a, b), (b, a)] {
            for leaf in try await holder.getLeaves() where leaf.isSpendable && leaf.valueSats <= 64 {
                candidates.append(Candidate(holder: holder, other: other, leaf: leaf))
            }
        }
        guard let start = candidates.min(by: { $0.leaf.refundTimelockBlocks < $1.leaf.refundTimelockBlocks }) else {
            Issue.record(Comment(rawValue: "no small spendable leaf to bounce"))
            return
        }
        var (holder, other, leaf) = (start.holder, start.other, start.leaf)
        let leafId = leaf.id
        print("bouncing leaf \(leafId) (\(leaf.valueSats) sats) from refund timelock \(leaf.refundTimelockBlocks)")
        while true {
            let arrivesAt = SparkWallet.roundedTimelock(leaf.refundTimelockBlocks) - sparkTimeLockInterval
            _ = try await holder.transferLeaves([leaf], receiverIdentityPublicKey: other.signer.identityPublicKey)
            try await Task.sleep(for: .seconds(3))
            let claim = try await other.claimPendingTransfers()
            #expect(claim.failures.isEmpty)
            (holder, other) = (other, holder)
            leaf = try #require(try await holder.getLeaves().first { $0.id == leafId })
            print("  delivered at \(arrivesAt), after the claim \(leaf.refundTimelockBlocks)")
            if arrivesAt < renewalThreshold {
                // Delivered in the renewal range: the claim pass renewed it.
                #expect(leaf.refundTimelockBlocks == 2000)
                #expect(leaf.isSpendable)
                break
            }
            #expect(leaf.refundTimelockBlocks == arrivesAt)
        }
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

// MARK: - Lightning sends

extension HardeningIntegrationTests {
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

    @Test("An amountless Lightning invoice is paid with the caller's amount", .timeLimit(.minutes(5)))
    func amountlessLightningInvoice() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let amount: Int64 = 12
        let invoice = try await pair.receiver.createLightningInvoice(amountSats: 0, memo: "amountless invoice test")
        #expect(try Bolt11Invoice.decode(invoice.paymentRequest).amountMsat == nil)
        let fee = try await pair.sender.getLightningSendFeeEstimate(encodedInvoice: invoice.paymentRequest, amountSats: amount)
        guard pair.senderSpendable >= amount + max(fee, 1) + 5 else {
            Issue.record(Comment(rawValue: "sender needs \(amount + max(fee, 1) + 5) spendable sats, has \(pair.senderSpendable)"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        let receiverBefore = try await pair.receiver.getBalance().satsBalance
        let requestId = try await pair.sender.payLightningInvoice(
            paymentRequest: invoice.paymentRequest, maxFeeSats: max(fee, 1) + 5, amountSats: amount
        )
        print("[\(pair.senderLabel)] paid an amountless invoice with \(amount) sats (fee estimate \(fee)): \(requestId)")
        try await Task.sleep(for: .seconds(5))
        _ = try await pair.receiver.claimPendingTransfers()
        let receiverAfter = try await pair.receiver.getBalance().satsBalance
        #expect(receiverAfter.owned >= receiverBefore.owned + amount)
    }

    @Test("A fee cap below the SSP estimate is refused before any leaf is locked", .timeLimit(.minutes(3)))
    func feeCapRefusal() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let invoice = try await pair.receiver.createLightningInvoice(amountSats: 10, memo: "fee cap test")
        let fee = try await pair.sender.getLightningSendFeeEstimate(encodedInvoice: invoice.paymentRequest)
        guard fee >= 1 else {
            Issue.record(Comment(rawValue: "the SSP quotes no fee for this invoice, so no cap can fall below it"))
            return
        }
        let before = try await pair.sender.getBalance()
        do {
            _ = try await pair.sender.payLightningInvoice(paymentRequest: invoice.paymentRequest, maxFeeSats: fee - 1)
            Issue.record(Comment(rawValue: "payment went through with a cap of \(fee - 1) (estimate \(fee))"))
        } catch SparkError.feeExceedsLimit(let quoted, let cap) {
            #expect(cap == fee - 1)
            #expect(quoted >= fee)
        }
        let after = try await pair.sender.getBalance()
        #expect(after.satsBalance.owned == before.satsBalance.owned)
        #expect(after.satsBalance.available == before.satsBalance.available)
    }

    @Test("An invoice pasted in upper case with surrounding whitespace is paid as validated", .timeLimit(.minutes(5)))
    func pastedInvoice() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let amount: Int64 = 10
        let invoice = try await pair.receiver.createLightningInvoice(amountSats: amount, memo: "pasted invoice test")
        let pasted = "  \(invoice.paymentRequest.uppercased())\n"
        let fee = try await pair.sender.getLightningSendFeeEstimate(encodedInvoice: invoice.paymentRequest)
        guard pair.senderSpendable >= amount + max(fee, 1) + 5 else {
            Issue.record(Comment(rawValue: "sender needs \(amount + max(fee, 1) + 5) spendable sats, has \(pair.senderSpendable)"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        let receiverBefore = try await pair.receiver.getBalance().satsBalance
        let requestId = try await pair.sender.payLightningInvoice(paymentRequest: pasted, maxFeeSats: max(fee, 1) + 5)
        print("[\(pair.senderLabel)] paid a pasted invoice: \(requestId)")
        var receiverAfter = receiverBefore
        for _ in 0..<10 where receiverAfter.owned < receiverBefore.owned + amount {
            try await Task.sleep(for: .seconds(3))
            _ = try await pair.receiver.claimPendingTransfers()
            receiverAfter = try await pair.receiver.getBalance().satsBalance
        }
        #expect(receiverAfter.owned == receiverBefore.owned + amount)
    }

    @Test("An interrupted Lightning send resumes from the transfer the coordinator holds and pays once", .timeLimit(.minutes(5)))
    func lightningSendResume() async throws {
        let pair = try await Self.makePair()
        defer { Task { await pair.sender.close(); await pair.receiver.close() } }
        let amount: Int64 = 10
        let invoice = try await pair.receiver.createLightningInvoice(amountSats: amount, memo: "resume test")
        let maxFee = max(try await pair.sender.getLightningSendFeeEstimate(encodedInvoice: invoice.paymentRequest), 1) + 5
        guard pair.senderSpendable >= 2 * (amount + maxFee) + 5 else {
            Issue.record(Comment(rawValue: "sender needs \(2 * (amount + maxFee) + 5) spendable sats, has \(pair.senderSpendable)"))
            return
        }
        _ = try await pair.receiver.claimPendingTransfers()
        let receiverBefore = try await pair.receiver.getBalance().satsBalance
        let payment = try LightningPayment(
            paymentRequest: invoice.paymentRequest, maxFeeSats: maxFee, amountSats: nil, idempotencyKey: nil, network: .mainnet
        )
        let transferId = UUID().uuidString.lowercased()

        // The first attempt ends after the swap, as when the SSP request fails: the coordinator
        // holds the leaves under the transfer id.
        let held = try await pair.sender.startLightningSend(payment, transferId: transferId)
        #expect(held.id == transferId)
        #expect(held.totalValue >= UInt64(amount))
        // The same swap again: the coordinator answers with the transfer it holds and locks nothing more.
        let availableBefore = try await pair.sender.getBalance().satsBalance.available
        let repeated = try await pair.sender.startLightningSend(payment, transferId: transferId)
        #expect(repeated.id == transferId)
        #expect(Set(repeated.leaves.map(\.leaf.id)) == Set(held.leaves.map(\.leaf.id)))
        #expect(try await pair.sender.getBalance().satsBalance.available == availableBefore)

        // Resuming selects no leaf: the SSP pays from the held transfer.
        let requestId = try await pair.sender.payLightningInvoice(
            paymentRequest: invoice.paymentRequest, maxFeeSats: maxFee, transferId: transferId
        )
        #expect(try await pair.sender.getBalance().satsBalance.available == availableBefore)
        // Paying again under the same id pays nothing twice: the SSP answers with its request.
        let again = try await pair.sender.payLightningInvoice(
            paymentRequest: invoice.paymentRequest, maxFeeSats: maxFee, transferId: transferId
        )
        #expect(again == requestId)
        // Another invoice cannot be paid from that transfer.
        let other = try await pair.receiver.createLightningInvoice(amountSats: amount, memo: "resume test, other invoice")
        await #expect(throws: SparkError.self) {
            _ = try await pair.sender.payLightningInvoice(paymentRequest: other.paymentRequest, maxFeeSats: maxFee, transferId: transferId)
        }
        print("[\(pair.senderLabel)] resumed transfer \(transferId) (\(held.totalValue) sats) as \(requestId)")

        var receiverAfter = receiverBefore
        for _ in 0..<10 where receiverAfter.owned < receiverBefore.owned + amount {
            try await Task.sleep(for: .seconds(3))
            _ = try await pair.receiver.claimPendingTransfers()
            receiverAfter = try await pair.receiver.getBalance().satsBalance
        }
        #expect(receiverAfter.owned == receiverBefore.owned + amount)
    }
}
