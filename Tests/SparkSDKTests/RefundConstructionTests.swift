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
