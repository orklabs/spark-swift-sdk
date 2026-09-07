import Foundation
import Testing
@testable import SparkSDK

private func p2trScript(_ byte: UInt8) -> Data { Data([0x51, 0x20]) + Data(repeating: byte, count: 32) }

/// A minimal node transaction (one input with the given timelock, one P2TR output).
private func nodeTx(timelock: UInt32, value: UInt64 = 10_000, tag: UInt8 = 0x11) -> Data {
    RawTransaction(
        version: 2,
        inputs: [RawTransaction.Input(previousTxid: Data(repeating: tag, count: 32), previousIndex: 0, sequence: (1 << 30) | timelock)],
        outputs: [RawTransaction.Output(value: value, scriptPubKey: p2trScript(tag))],
        locktime: 0, hasWitnessSerialization: false
    ).serialized(includeWitness: true)
}

@Suite("Cooperative exit refund construction")
struct ConnectorRefundTests {
    private let receiver = try! KeyDerivation(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", account: 0).identityPublicKey
    private let connectorTx = RawTransaction(
        version: 2,
        inputs: [RawTransaction.Input(previousTxid: Data(repeating: 0xEE, count: 32), previousIndex: 1)],
        outputs: [RawTransaction.Output(value: 330, scriptPubKey: Data([0x00, 0x14]) + Data(repeating: 0x77, count: 20)),
                  RawTransaction.Output(value: 331, scriptPubKey: Data([0x00, 0x14]) + Data(repeating: 0x78, count: 20)),
                  RawTransaction.Output(value: 5_000, scriptPubKey: Data([0x00, 0x14]) + Data(repeating: 0x79, count: 20))],
        locktime: 0, hasWitnessSerialization: false
    )

    private func node(nodeTimelock: UInt32, refundTimelock: UInt32, withDirect: Bool) -> Spark_TreeNode {
        var node = Spark_TreeNode()
        node.id = "leaf"
        node.nodeTx = nodeTx(timelock: nodeTimelock)
        node.refundTx = nodeTx(timelock: refundTimelock, value: 9_045, tag: 0x22)
        if withDirect { node.directTx = nodeTx(timelock: nodeTimelock + 50, tag: 0x33) }
        return node
    }

    @Test("Refunds spend the node output first and the connector output second, sighash over both prevouts")
    func connectorRefunds() throws {
        let leaf = node(nodeTimelock: 1000, refundTimelock: 2000, withDirect: true)
        let refunds = try SparkWallet.buildConnectorRefunds(
            node: leaf, receiverPubKey: receiver, connectorTxid: connectorTx.txid,
            connectorTx: connectorTx, connectorVout: 1, network: "mainnet"
        )
        let nodeTxid = try RawTransaction.parse(leaf.nodeTx).txid
        for (label, refund) in [("cpfp", refunds.cpfp), ("directFromCpfp", refunds.directFromCpfp)] {
            let tx = try RawTransaction.parse(refund.tx)
            #expect(tx.inputs.count == 2, Comment(rawValue: label))
            #expect(tx.inputs[0].previousTxid == nodeTxid, Comment(rawValue: label))
            #expect(tx.inputs[0].previousIndex == 0)
            #expect(tx.inputs[1].previousTxid == connectorTx.txid, Comment(rawValue: label))
            #expect(tx.inputs[1].previousIndex == 1)
            #expect(tx.inputs[1].sequence == 0xFFFF_FFFF)
            #expect(refund.sighash.count == 32)
            let recomputed = try computeMultiInputSighashUniffi(
                tx: refund.tx, inputIndex: 0,
                prevOutScripts: [p2trScript(0x11), connectorTx.outputs[1].scriptPubKey],
                prevOutValues: [10_000, 331]
            )
            #expect(recomputed == refund.sighash, Comment(rawValue: label))
        }
        // Timelocks step down by one interval; the direct refund carries the direct offset.
        #expect(try RawTransaction.parse(refunds.cpfp.tx).inputs[0].sequence & 0xFFFF == 1900)
        #expect(try RawTransaction.parse(refunds.directFromCpfp.tx).inputs[0].sequence & 0xFFFF == 1950)
        let direct = try #require(refunds.direct)
        let directTx = try RawTransaction.parse(direct.tx)
        #expect(directTx.inputs.count == 2)
        #expect(directTx.inputs[0].previousTxid == (try RawTransaction.parse(leaf.directTx).txid))
        #expect(directTx.inputs[0].sequence & 0xFFFF == 1950)
        #expect(direct.sighash != refunds.cpfp.sighash)
        #expect(refunds.cpfp.sighash != refunds.directFromCpfp.sighash)
    }

    @Test("No direct refund for zero-timelock nodes or leaves without a direct node transaction")
    func directRefundRules() throws {
        let zeroNode = node(nodeTimelock: 0, refundTimelock: 2000, withDirect: true)
        let zeroRefunds = try SparkWallet.buildConnectorRefunds(
            node: zeroNode, receiverPubKey: receiver, connectorTxid: connectorTx.txid,
            connectorTx: connectorTx, connectorVout: 0, network: "mainnet"
        )
        #expect(zeroRefunds.direct == nil)
        let noDirect = node(nodeTimelock: 1000, refundTimelock: 2000, withDirect: false)
        let noDirectRefunds = try SparkWallet.buildConnectorRefunds(
            node: noDirect, receiverPubKey: receiver, connectorTxid: connectorTx.txid,
            connectorTx: connectorTx, connectorVout: 0, network: "mainnet"
        )
        #expect(noDirectRefunds.direct == nil)
        // A leaf at the timelock floor cannot be exited cooperatively.
        let floor = node(nodeTimelock: 1000, refundTimelock: 100, withDirect: false)
        #expect(throws: SparkError.self) {
            _ = try SparkWallet.buildConnectorRefunds(node: floor, receiverPubKey: receiver, connectorTxid: connectorTx.txid, connectorTx: connectorTx, connectorVout: 0, network: "mainnet")
        }
        // The connector output must exist.
        #expect(throws: SparkError.self) {
            _ = try SparkWallet.buildConnectorRefunds(node: noDirect, receiverPubKey: receiver, connectorTxid: connectorTx.txid, connectorTx: connectorTx, connectorVout: 9, network: "mainnet")
        }
    }
}

@Suite("Balance summary")
struct BalanceSummaryTests {
    private func treeNode(_ id: String, status: String, value: UInt64, refundTimelock: UInt32) -> Spark_TreeNode {
        var node = Spark_TreeNode()
        node.id = id
        node.status = status
        node.value = value
        node.refundTx = nodeTx(timelock: refundTimelock)
        return node
    }

    @Test("Available excludes floor-timelock leaves, which are reported as frozen; locked adds to owned only")
    func summary() {
        let nodes: [String: Spark_TreeNode] = [
            "a": treeNode("a", status: "AVAILABLE", value: 8192, refundTimelock: 1600),
            "b": treeNode("b", status: "AVAILABLE", value: 32, refundTimelock: 0),
            "c": treeNode("c", status: "AVAILABLE", value: 2, refundTimelock: 100),
            "d": treeNode("d", status: "TRANSFER_LOCKED", value: 500, refundTimelock: 2000),
            "e": treeNode("e", status: "CREATING", value: 700, refundTimelock: 2000),
            "f": treeNode("f", status: "SPLIT_LOCKED", value: 9, refundTimelock: 2000),
            "g": treeNode("g", status: "AVAILABLE", value: 64, refundTimelock: 200),
        ]
        let s = SparkWallet.summarizeNodes(nodes)
        #expect(s.available == 8192 + 64)
        #expect(s.frozen == 32 + 2)
        #expect(s.owned == 8192 + 32 + 2 + 500 + 9 + 64)
        #expect(s.creating == 700)
        #expect(Set(s.leaves.map(\.id)) == ["a", "b", "c", "g"])
        #expect(SparkWallet.summarizeNodes([:]) == SparkWallet.NodeSummary())
    }
}
