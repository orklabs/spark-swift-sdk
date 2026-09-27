import Foundation
import Testing
@testable import SparkSDK

/// Renewal transactions must be exactly what the operators rebuild and compare byte for byte
/// (`renew_leaf_handler.go`): the new node (or split node) spends the parent's output at the
/// leaf's `vout` and pays P2TR(leaf verifying key); the zero-timelock variant spends the leaf's
/// own node transaction. Renewals used to spend parent output 0, so a leaf at another output
/// could never be renewed.
@Suite("Leaf renewal transactions")
struct RenewalTransactionTests {
    private let config = SparkConfig(network: .mainnet)
    private let verifyingKey: Data
    private let signingPublicKey: Data
    private let otherKey: Data

    init() throws {
        let signer = try SparkSigner(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", account: 0
        )
        verifyingKey = signer.identityPublicKey
        signingPublicKey = try signer.deriveLeafSigningKeyPair("leaf").publicKey
        otherKey = try signer.deriveLeafSigningKeyPair("sibling").publicKey
    }

    private func p2tr(_ key: Data) throws -> Data {
        Data([0x51, 0x20]) + (try getTaprootPubkey(verifyingPubkey: key)).dropFirst()
    }

    private func tx(inputSequence: UInt32, outputs: [RawTransaction.Output]) -> Data {
        RawTransaction(
            version: 3,
            inputs: [RawTransaction.Input(previousTxid: Data(repeating: 0xAB, count: 32), previousIndex: 0, sequence: inputSequence)],
            outputs: outputs,
            locktime: 0, hasWitnessSerialization: false
        ).serialized(includeWitness: true)
    }

    /// A parent node transaction that split into a sibling at output 0 and our leaf at output 1.
    private func parentAndLeaf() throws -> (parent: Spark_TreeNode, leaf: Spark_TreeNode) {
        var parent = Spark_TreeNode()
        parent.id = "parent"
        parent.nodeTx = tx(inputSequence: 1 << 30, outputs: [
            RawTransaction.Output(value: 3_000, scriptPubKey: try p2tr(otherKey)),
            RawTransaction.Output(value: 5_000, scriptPubKey: try p2tr(verifyingKey)),
        ])
        var leaf = Spark_TreeNode()
        leaf.id = "leaf"
        leaf.parentNodeID = parent.id
        leaf.vout = 1
        leaf.verifyingPublicKey = verifyingKey
        leaf.nodeTx = tx(inputSequence: (1 << 30) | 2000,
                         outputs: [RawTransaction.Output(value: 5_000, scriptPubKey: try p2tr(verifyingKey))])
        leaf.refundTx = tx(inputSequence: (1 << 30) | 150,
                           outputs: [RawTransaction.Output(value: 5_000, scriptPubKey: try p2tr(signingPublicKey))])
        return (parent, leaf)
    }

    @Test("The leaf's node address is its verifying key with the BIP-86 tweak")
    func leafNodeAddress() throws {
        // BIP-86 test vector: internal key cc8a4bc6… -> bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr
        let internalKey = try #require(Data(hexString: "02cc8a4bc64d897bddc5fbc2f670f7a8ba0b386779106cf1223c6fc5d7cd6fc115"))
        #expect(try SparkWallet.leafNodeAddress(verifyingKey: internalKey, network: .mainnet)
                == "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")
    }

    @Test("Refund renewal spends the parent's output at the leaf's vout and pays the leaf's node address")
    func refundRenewal() throws {
        let (parent, leaf) = try parentAndLeaf()
        let txs = try SparkWallet.refundRenewalTransactions(node: leaf, parent: parent, signingPublicKey: signingPublicKey, config: config)
        let parentTxid = try RawTransaction.parse(parent.nodeTx).txid
        for nodeTx in [txs.node.cpfp.tx, txs.node.direct.tx] {
            let parsed = try RawTransaction.parse(nodeTx)
            #expect(parsed.inputs[0].previousTxid == parentTxid)
            #expect(parsed.inputs[0].previousIndex == 1)
            #expect(parsed.outputs[0].scriptPubKey == (try p2tr(verifyingKey)))
        }
        #expect(try RawTransaction.parse(txs.node.cpfp.tx).outputs[0].value == 5_000)
        #expect(try RawTransaction.parse(txs.node.cpfp.tx).inputs[0].sequence == (1 << 30) | 1900)
        #expect(try RawTransaction.parse(txs.refunds.cpfpRefund.tx).inputs[0].sequence & 0xFFFF == 2000)
        #expect(txs.split == nil)
    }

    @Test("Node renewal's split node spends the parent's output at the leaf's vout")
    func nodeRenewal() throws {
        let (parent, leaf) = try parentAndLeaf()
        let txs = try SparkWallet.nodeRenewalTransactions(node: leaf, parent: parent, signingPublicKey: signingPublicKey, config: config)
        let split = try #require(txs.split)
        let splitTx = try RawTransaction.parse(split.cpfp.tx)
        #expect(splitTx.inputs[0].previousTxid == (try RawTransaction.parse(parent.nodeTx).txid))
        #expect(splitTx.inputs[0].previousIndex == 1)
        #expect(splitTx.inputs[0].sequence & 0xFFFF == 0)
        #expect(splitTx.outputs[0].scriptPubKey == (try p2tr(verifyingKey)))
        #expect(splitTx.outputs[0].value == 5_000)
        let nodeTx = try RawTransaction.parse(txs.node.cpfp.tx)
        #expect(nodeTx.inputs[0].previousTxid == splitTx.txid)
        #expect(nodeTx.inputs[0].previousIndex == 0)
        #expect(nodeTx.inputs[0].sequence & 0xFFFF == 2000)
        #expect(nodeTx.outputs[0].scriptPubKey == (try p2tr(verifyingKey)))
    }

    @Test("Zero-timelock renewal spends the leaf's own node transaction")
    func zeroTimelockRenewal() throws {
        var (_, leaf) = try parentAndLeaf()
        leaf.nodeTx = tx(inputSequence: 1 << 30, outputs: [RawTransaction.Output(value: 5_000, scriptPubKey: try p2tr(verifyingKey))])
        let txs = try SparkWallet.zeroTimelockRenewalTransactions(node: leaf, signingPublicKey: signingPublicKey, config: config)
        let nodeTx = try RawTransaction.parse(txs.node.cpfp.tx)
        #expect(nodeTx.inputs[0].previousTxid == (try RawTransaction.parse(leaf.nodeTx).txid))
        #expect(nodeTx.inputs[0].previousIndex == 0)
        #expect(nodeTx.inputs[0].sequence & 0xFFFF == 0)
        #expect(nodeTx.outputs[0].scriptPubKey == (try p2tr(verifyingKey)))
        #expect(txs.refunds.directRefund == nil)
    }
}
