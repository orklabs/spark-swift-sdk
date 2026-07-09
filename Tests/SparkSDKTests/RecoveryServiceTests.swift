import Foundation
import Testing
@testable import SparkSDK

private func makeNode(
    id: String,
    parent: String? = nil,
    owner: Data,
    status: String,
    value: UInt64 = 1000,
    refundTx: Data = Data([0xbe, 0xef])
) -> Spark_TreeNode {
    var node = Spark_TreeNode()
    node.id = id
    node.treeID = "tree-1"
    node.value = value
    if let parent { node.parentNodeID = parent }
    node.nodeTx = Data([0xde, 0xad])
    node.refundTx = refundTx
    node.ownerIdentityPublicKey = owner
    node.status = status
    return node
}

@Test("Recovery snapshot classifies leaves vs ancestors and round-trips hex")
func recoverySnapshotClassification() throws {
    let me = Data(repeating: 0x02, count: 33)
    // root -> mid -> leaf chain, plus an unrelated available leaf
    let root = makeNode(id: "root", owner: me, status: "SPLITTED")
    let mid = makeNode(id: "mid", parent: "root", owner: me, status: "SPLITTED")
    let leaf = makeNode(id: "leaf", parent: "mid", owner: me, status: "AVAILABLE", value: 5000)
    let lockedLeaf = makeNode(id: "locked", parent: "root", owner: me, status: "TRANSFER_LOCKED", value: 250)

    let all = ["root": root, "mid": mid, "leaf": leaf, "locked": lockedLeaf]
    #expect(SparkWallet.missingParentIds(in: all).isEmpty)

    let snapshot = try SparkWallet.buildRecoverySnapshot(
        from: all, identityPublicKey: me, network: "MAINNET"
    )

    #expect(snapshot.network == "MAINNET")
    #expect(snapshot.leaves.map(\.id) == ["leaf", "locked"])
    #expect(snapshot.nodes.map(\.id) == ["mid", "root"])
    #expect(snapshot.totalLeafSats == 5250)

    // Hex must decode back to an identical TreeNode carrying the refund tx.
    let leafHex = snapshot.leaves.first { $0.id == "leaf" }!.treeNodeHex
    let decoded = try Spark_TreeNode(serializedBytes: Data(hexString: leafHex)!)
    #expect(decoded == leaf)
    #expect(!decoded.refundTx.isEmpty)
}

@Test("Missing parents are detected so the repair pass can re-fetch them")
func missingParentDetection() {
    let me = Data(repeating: 0x02, count: 33)
    // Leaf references a parent the bulk query omitted (legacy-root gotcha).
    let leaf = makeNode(id: "leaf", parent: "ghost-root", owner: me, status: "AVAILABLE")
    #expect(SparkWallet.missingParentIds(in: ["leaf": leaf]) == ["ghost-root"])
}

@Test("Nodes owned by someone else never classify as leaves")
func foreignNodesAreAncestorsOnly() throws {
    let me = Data(repeating: 0x02, count: 33)
    let them = Data(repeating: 0x03, count: 33)
    let foreign = makeNode(id: "foreign", owner: them, status: "AVAILABLE")

    let snapshot = try SparkWallet.buildRecoverySnapshot(
        from: ["foreign": foreign], identityPublicKey: me, network: "MAINNET"
    )
    #expect(snapshot.leaves.isEmpty)
    #expect(snapshot.nodes.map(\.id) == ["foreign"])
}
