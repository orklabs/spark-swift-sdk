import Foundation
import Testing
@testable import SparkSDK

private func p2trScript(_ byte: UInt8) -> Data { Data([0x51, 0x20]) + Data(repeating: byte, count: 32) }

/// A minimal node transaction: one input with the given timelock (bit 30 set), one P2TR output.
private func nodeTx(timelock: UInt32, value: UInt64 = 10_000, tag: UInt8 = 0x11) -> Data {
    RawTransaction(
        version: 3,
        inputs: [RawTransaction.Input(previousTxid: Data(repeating: tag, count: 32), previousIndex: 0, sequence: (1 << 30) | timelock)],
        outputs: [RawTransaction.Output(value: value, scriptPubKey: p2trScript(tag))],
        locktime: 0, hasWitnessSerialization: false
    ).serialized(includeWitness: true)
}

/// The refunds a send or a claim signs for a leaf. The operators' rule
/// (`base_transfer_handler.go`: "zero nodes must not have a direct refund tx", with
/// `IsZeroNode` = node transaction timelock 0) and the reference SDK's `isZeroNode` check decide
/// whether a direct refund is built.
@Suite("Leaf refund construction")
struct RefundConstructionTests {
    private let receiver: Data

    init() throws {
        receiver = try KeyDerivation(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", account: 0
        ).identityPublicKey
    }

    private func leaf(nodeTimelock: UInt32, withDirect: Bool) -> Spark_TreeNode {
        var node = Spark_TreeNode()
        node.id = "leaf"
        node.nodeTx = nodeTx(timelock: nodeTimelock)
        node.refundTx = nodeTx(timelock: 2000, value: 9_045, tag: 0x22)
        if withDirect { node.directTx = nodeTx(timelock: nodeTimelock + 50, tag: 0x33) }
        return node
    }

    private func trio(_ node: Spark_TreeNode) throws -> RefundTxTrioResult {
        let (cpfp, direct) = try SparkWallet.computeNextSequences(from: Data(node.refundTx))
        return try SparkWallet.leafRefundTrio(
            node: node, receivingPubkey: receiver, network: "mainnet", sequence: cpfp, directSequence: direct
        )
    }

    @Test("A zero-timelock node gets no direct refund, even with a direct node transaction")
    func zeroNode() throws {
        // Zero-timelock renewal leaves this shape: node transaction at timelock 0 plus a direct one.
        let zero = leaf(nodeTimelock: 0, withDirect: true)
        #expect(try SparkWallet.isZeroTimelockNode(Data(zero.nodeTx)))
        #expect(try SparkWallet.directNodeTxForRefund(zero) == nil)
        let refunds = try trio(zero)
        #expect(refunds.directRefund == nil)
        let nodeTxid = try RawTransaction.parse(zero.nodeTx).txid
        #expect(try RawTransaction.parse(refunds.cpfpRefund.tx).inputs[0].previousTxid == nodeTxid)
        #expect(try RawTransaction.parse(refunds.directFromCpfpRefund.tx).inputs[0].previousTxid == nodeTxid)
    }

    @Test("A timelocked node with a direct node transaction gets a direct refund spending it")
    func timelockedNode() throws {
        let node = leaf(nodeTimelock: 1000, withDirect: true)
        #expect(try !SparkWallet.isZeroTimelockNode(Data(node.nodeTx)))
        #expect(try SparkWallet.directNodeTxForRefund(node) == Data(node.directTx))
        let direct = try #require(try trio(node).directRefund)
        let directTx = try RawTransaction.parse(direct.tx)
        #expect(directTx.inputs[0].previousTxid == (try RawTransaction.parse(node.directTx).txid))
        #expect(directTx.inputs[0].sequence & 0xFFFF == 1950)
    }

    @Test("A leaf without a direct node transaction gets no direct refund")
    func noDirectNodeTx() throws {
        let node = leaf(nodeTimelock: 1000, withDirect: false)
        #expect(try SparkWallet.directNodeTxForRefund(node) == nil)
        #expect(try trio(node).directRefund == nil)
    }
}

/// Refund timelock arithmetic, pinned to the operators' own test vectors
/// (`validation_test.go`: RoundDownToTimelockInterval, ValidateSequence misaligned/aligned/floor)
/// and the reference SDK's (`transaction-construction.test.ts`: createDecrementedTimelockRefundTxs).
@Suite("Refund timelock arithmetic")
struct TimelockArithmeticTests {
    private func refundTx(_ timelock: UInt32) -> Data { nodeTx(timelock: timelock) }

    @Test("Timelocks round down to the 100-block interval like the operators'")
    func rounding() {
        let vectors: [(UInt32, UInt32)] = [(100, 100), (1000, 1000), (740, 700), (670, 600), (0, 0), (1970, 1900), (1870, 1800)]
        for (timelock, rounded) in vectors {
            #expect(SparkWallet.roundedTimelock(timelock) == rounded)
        }
    }

    @Test("The next refund is the rounded timelock minus 100, and the direct refunds 50 above it")
    func nextSequences() throws {
        // (current refund timelock, expected next CPFP timelock)
        let vectors: [(UInt32, UInt32)] = [
            (2000, 1900), // reference SDK: decrements by TIME_LOCK_INTERVAL
            (550, 400),   // reference SDK: a non-aligned 550 rounds to 500, then decrements
            (740, 600),   // operators: 600 accepted for a 740 leaf, 640 rejected
            (700, 600),   // operators: aligned
            (1000, 900),  // operators: 1000 expects 900
            (200, 100),
        ]
        for (current, next) in vectors {
            let (cpfp, direct) = try SparkWallet.computeNextSequences(from: refundTx(current))
            #expect(cpfp == (1 << 30) | next, "current \(current)")
            #expect(direct == (1 << 30) | (next + 50), "current \(current)")
        }
        // Every aligned and misaligned value the operators accept: RoundDown(t) - 100.
        for current in UInt32(200)...2100 {
            let (cpfp, _) = try SparkWallet.computeNextSequences(from: refundTx(current))
            #expect(cpfp & 0xFFFF == current - current % 100 - 100)
        }
    }

    @Test("A refund timelock that rounds to 100 or less cannot be decremented without a renewal")
    func floor() {
        for current: UInt32 in [0, 50, 99, 100, 101, 150, 199] {
            #expect(throws: SparkError.self) { _ = try SparkWallet.computeNextSequences(from: refundTx(current)) }
            #expect(!SparkWallet.timelockCanDecrement(refundTx(current)))
        }
        #expect(SparkWallet.timelockCanDecrement(refundTx(200)))
        #expect(SparkWallet.timelockCanDecrement(refundTx(740)))
    }

    @Test("Lightning HTLC refunds are not rounded: refund sequence minus 30 and minus 15, as the operators rebuild them")
    func htlcSequences() throws {
        // Current refund timelock -> (CPFP HTLC, direct HTLC) timelocks.
        let vectors: [UInt32: [UInt32]] = [2000: [1970, 1985], 740: [710, 725], 1234: [1204, 1219]]
        for (current, expected) in vectors {
            let sequences = try SparkWallet.htlcSequences(from: refundTx(current))
            #expect(sequences.cpfp == (1 << 30) | expected[0], "current \(current)")
            #expect(sequences.direct == (1 << 30) | expected[1], "current \(current)")
        }
        #expect(throws: SparkError.self) { _ = try SparkWallet.htlcSequences(from: refundTx(100)) }
    }
}
