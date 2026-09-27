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

    @Test("Leaves below the renewal minimum are frozen; renewable leaves count as available; other statuses are ignored")
    func summary() {
        let nodes: [String: Spark_TreeNode] = [
            "a": treeNode("a", status: "AVAILABLE", value: 8192, refundTimelock: 1600),
            "b": treeNode("b", status: "AVAILABLE", value: 32, refundTimelock: 0),
            "c": treeNode("c", status: "AVAILABLE", value: 2, refundTimelock: 100),
            "d": treeNode("d", status: "TRANSFER_LOCKED", value: 500, refundTimelock: 2000),
            "e": treeNode("e", status: "CREATING", value: 700, refundTimelock: 2000),
            // A renewal split node: permanently SPLIT_LOCKED, still carrying the owner key.
            "f": treeNode("f", status: "SPLIT_LOCKED", value: 9, refundTimelock: 2000),
            "g": treeNode("g", status: "AVAILABLE", value: 64, refundTimelock: 200),
            "h": treeNode("h", status: "AVAILABLE", value: 16, refundTimelock: 150),
            "i": treeNode("i", status: "AVAILABLE", value: 4, refundTimelock: 99),
        ]
        let summary = SparkWallet.summarizeNodes(nodes)
        // 100 and 150 are renewable (the coordinator renews refund timelocks from 100), so they
        // are available; 0 and 99 are below the renewal minimum and frozen.
        #expect(summary.available == 8192 + 2 + 64 + 16)
        #expect(summary.frozen == 32 + 4)
        #expect(Set(summary.leaves.map(\.id)) == ["a", "b", "c", "g", "h", "i"])
        let empty = SparkWallet.summarizeNodes([:])
        #expect(empty.available == 0 && empty.frozen == 0 && empty.leaves.isEmpty)
    }

    private func transfer(_ id: String, leaves: [(String, UInt64)]) -> Spark_Transfer {
        var transfer = Spark_Transfer()
        transfer.id = id
        transfer.leaves = leaves.map { leafId, value in
            var transferLeaf = Spark_TransferLeaf()
            transferLeaf.leaf.id = leafId
            transferLeaf.leaf.value = value
            return transferLeaf
        }
        return transfer
    }

    @Test("In-flight sats count each leaf once and never a leaf that is already available")
    func inFlight() {
        let transfers = [
            transfer("outgoing", leaves: [("l1", 500), ("l2", 20)]),
            // A self-transfer, or a counter-swap leaf mid-claim, shows up in two queries.
            transfer("counter", leaves: [("l2", 20), ("l3", 8)]),
            transfer("claimed", leaves: [("available-leaf", 64)]),
        ]
        #expect(SparkWallet.leafSats(transfers, excludingLeafIds: ["available-leaf"]) == 500 + 20 + 8)
        #expect(SparkWallet.leafSats([], excludingLeafIds: []) == 0)
        var withoutNode = Spark_Transfer()
        withoutNode.leaves = [Spark_TransferLeaf()]
        #expect(SparkWallet.leafSats([withoutNode], excludingLeafIds: []) == 0)
    }

    @Test("Amounts an operator reports above the bitcoin supply are capped instead of crashing the app")
    func hostileAmounts() {
        #expect(Int64(reportedSats: 0) == 0)
        #expect(Int64(reportedSats: 12_345) == 12_345)
        #expect(Int64(reportedSats: UInt64(Int64.maxSupplySats)) == Int64.maxSupplySats)
        #expect(Int64(reportedSats: UInt64(Int64.max) + 1) == Int64.maxSupplySats)
        #expect(Int64(reportedSats: .max) == Int64.maxSupplySats)

        var hostile = Spark_Transfer()
        hostile.id = "hostile"
        hostile.totalValue = .max
        #expect(SparkTransfer(hostile).totalValueSats == Int64.maxSupplySats)

        // Two such leaves still add up without overflowing.
        let nodes = [
            "x": treeNode("x", status: "AVAILABLE", value: .max, refundTimelock: 2000),
            "y": treeNode("y", status: "AVAILABLE", value: .max, refundTimelock: 50),
        ]
        let summary = SparkWallet.summarizeNodes(nodes)
        #expect(summary.available == Int64.maxSupplySats)
        #expect(summary.frozen == Int64.maxSupplySats)
        #expect(SparkWallet.leafSats([transfer("t", leaves: [("l1", .max), ("l2", .max)])], excludingLeafIds: [])
                == 2 * Int64.maxSupplySats)
    }

    @Test("Incoming leaves out counter-transfers of the wallet's own swaps and leaves counted elsewhere")
    func incoming() {
        var counterSwap = transfer("counter", leaves: [("c1", 512)])
        counterSwap.type = .counterSwapV3
        var legacyCounterSwap = transfer("legacy-counter", leaves: [("c2", 256)])
        legacyCounterSwap.type = .counterSwap
        var payment = transfer("lightning", leaves: [("p1", 1_000), ("p2", 24)])
        payment.type = .preimageSwap
        var selfTransfer = transfer("self", leaves: [("s1", 7)])
        selfTransfer.type = .transfer
        let pending = [counterSwap, legacyCounterSwap, payment, selfTransfer]
        // The self-transfer's leaf is already counted as outgoing.
        let me = Data([0x02] + Array(repeating: 0x33, count: 32))
        #expect(SparkWallet.incomingSats(pending, excludingLeafIds: ["s1"], receiver: me) == 1_000 + 24)
        #expect(SparkWallet.incomingSats(pending, excludingLeafIds: [], receiver: me) == 1_000 + 24 + 7)

        // A multi-receiver payment counts only this wallet's leaves.
        var split = transfer("split", leaves: [("m1", 300), ("m2", 200), ("m3", 100)])
        split.type = .transfer
        split.receivers = [("edge-me", me), ("edge-other", Data([0x03] + Array(repeating: 0x44, count: 32)))].map { id, key in
            var receiver = Spark_TransferReceiver()
            receiver.id = id
            receiver.identityPublicKey = key
            return receiver
        }
        for (index, edge) in ["edge-me", "edge-other", "edge-me"].enumerated() {
            split.leaves[index].transferReceiverID = edge
        }
        #expect(SparkWallet.incomingSats([split], excludingLeafIds: [], receiver: me) == 300 + 100)
    }

    @Test("In-flight transfers are queried with the reference SDK's types and statuses")
    func inFlightQuerySets() {
        // transfer.ts SENDER_PENDING_STATUSES: before the sender key tweak is applied.
        #expect(SparkWallet.senderPendingStatuses == [
            .senderInitiated, .senderInitiatedCoordinator, .applyingSenderKeyTweak, .senderKeyTweakPending,
        ])
        // ACTIVE_COUNTER_SWAP_STATUSES: the whole counter-transfer lifecycle until completion.
        #expect(SparkWallet.activeCounterSwapStatuses == SparkWallet.senderPendingStatuses + [
            .senderKeyTweaked, .receiverKeyTweakLocked, .receiverKeyTweakApplied, .receiverKeyTweaked, .receiverRefundSigned,
        ])
        #expect(!SparkWallet.activeCounterSwapStatuses.contains(.completed))
        #expect(SparkWallet.outgoingTransferTypes == [.cooperativeExit, .utxoSwap, .preimageSwap, .transfer])
        #expect(SparkWallet.primarySwapTypes == [.primarySwapV3, .swap])
        #expect(SparkWallet.counterSwapTypes == [.counterSwapV3, .counterSwap])
    }
}
