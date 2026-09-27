import Foundation
import Testing
@testable import SparkSDK

/// The sender-signature check that runs before an inbound transfer is claimed.
@Suite("Inbound transfer verification")
struct ClaimVerificationTests {

    private let sender = try! KeyDerivation(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", account: 0)
    private let receiver = try! KeyDerivation(mnemonic: "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic", account: 0)

    private func leaf(id: String, transferId: String, cipher: Data, signWith key: KeyDerivation? = nil, compact: Bool = true) throws -> Spark_TransferLeaf {
        var node = Spark_TreeNode()
        node.id = id
        var leaf = Spark_TransferLeaf()
        leaf.leaf = node
        leaf.secretCipher = cipher
        if let key {
            let digest = TransferLeafVerifier.payloadHash(leafId: id, transferId: transferId, secretCipher: cipher)
            leaf.signature = compact
                ? try key.signCompactECDSA(messageHash: digest, with: key.identityPrivateKey)
                : try key.signECDSA(messageHash: digest, with: key.identityPrivateKey)
        }
        return leaf
    }

    private func transfer(_ leaves: [Spark_TransferLeaf], id: String = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b") -> Spark_Transfer {
        var t = Spark_Transfer()
        t.id = id
        t.senderIdentityPublicKey = sender.identityPublicKey
        t.receiverIdentityPublicKey = receiver.identityPublicKey
        t.leaves = leaves
        return t
    }

    @Test("Compact and DER signatures from the sender's identity key verify")
    func validSignatures() throws {
        let digest = TransferLeafVerifier.payloadHash(leafId: "leaf-1", transferId: "tx-1", secretCipher: Data([1, 2, 3]))
        #expect(digest.count == 32)
        let compact = try sender.signCompactECDSA(messageHash: digest, with: sender.identityPrivateKey)
        let der = try sender.signECDSA(messageHash: digest, with: sender.identityPrivateKey)
        #expect(compact.count == 64)
        #expect(TransferLeafVerifier.verifyECDSA(signature: compact, digest: digest, compressedPublicKey: sender.identityPublicKey))
        #expect(TransferLeafVerifier.verifyECDSA(signature: der, digest: digest, compressedPublicKey: sender.identityPublicKey))
    }

    @Test("Wrong key, tampered payload, malformed or empty signatures are rejected without crashing")
    func invalidSignatures() throws {
        let digest = TransferLeafVerifier.payloadHash(leafId: "leaf-1", transferId: "tx-1", secretCipher: Data([1, 2, 3]))
        let compact = try sender.signCompactECDSA(messageHash: digest, with: sender.identityPrivateKey)
        let tampered = TransferLeafVerifier.payloadHash(leafId: "leaf-1", transferId: "tx-2", secretCipher: Data([1, 2, 3]))

        #expect(!TransferLeafVerifier.verifyECDSA(signature: compact, digest: tampered, compressedPublicKey: sender.identityPublicKey))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: compact, digest: digest, compressedPublicKey: receiver.identityPublicKey))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: Data(), digest: digest, compressedPublicKey: sender.identityPublicKey))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: Data(repeating: 0, count: 64), digest: digest, compressedPublicKey: sender.identityPublicKey))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: Data([0x30, 0x01]), digest: digest, compressedPublicKey: sender.identityPublicKey))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: compact, digest: Data([1]), compressedPublicKey: sender.identityPublicKey))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: compact, digest: digest, compressedPublicKey: Data(repeating: 0x04, count: 65)))
        #expect(!TransferLeafVerifier.verifyECDSA(signature: compact, digest: digest, compressedPublicKey: Data(repeating: 0x02, count: 33)))
        var flipped = compact
        flipped[10] ^= 0x01
        #expect(!TransferLeafVerifier.verifyECDSA(signature: flipped, digest: digest, compressedPublicKey: sender.identityPublicKey))
    }

    @Test("A transfer whose leaves are all signed by the sender passes")
    func acceptsSignedTransfer() throws {
        let id = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let t = transfer([
            try leaf(id: "leaf-a", transferId: id, cipher: Data(repeating: 1, count: 40), signWith: sender),
            try leaf(id: "leaf-b", transferId: id, cipher: Data(repeating: 2, count: 40), signWith: sender, compact: false),
        ], id: id)
        try TransferLeafVerifier.verify(transfer: t, receiverIdentityPublicKey: receiver.identityPublicKey)
    }

    @Test("Unsigned, wrongly signed, incomplete or misaddressed transfers are refused")
    func refusesBadTransfers() throws {
        let id = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let good = try leaf(id: "leaf-a", transferId: id, cipher: Data(repeating: 1, count: 40), signWith: sender)

        // One good leaf, one unsigned leaf.
        let unsigned = try leaf(id: "leaf-b", transferId: id, cipher: Data(repeating: 2, count: 40))
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([good, unsigned], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        // Signed by someone other than the transfer's sender.
        let impostor = try leaf(id: "leaf-b", transferId: id, cipher: Data(repeating: 2, count: 40), signWith: receiver)
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([good, impostor], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        // Signature made for a different transfer id.
        let replayed = try leaf(id: "leaf-b", transferId: "other-transfer", cipher: Data(repeating: 2, count: 40), signWith: sender)
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([good, replayed], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        // Cipher swapped after signing.
        var swapped = good
        swapped.secretCipher = Data(repeating: 9, count: 40)
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([swapped], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        // Missing node, empty cipher, no leaves, wrong receiver.
        var noNode = good
        noNode.clearLeaf()
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([noNode], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        var emptyCipher = good
        emptyCipher.secretCipher = Data()
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([emptyCipher], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([], id: id), receiverIdentityPublicKey: receiver.identityPublicKey)
        }
        #expect(throws: SparkError.self) {
            try TransferLeafVerifier.verify(transfer: transfer([good], id: id), receiverIdentityPublicKey: sender.identityPublicKey)
        }
    }

    @Test("A multi-receiver transfer is claimed for this wallet's own leaves, whichever receiver the operators recorded")
    func multiReceiver() throws {
        let id = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let other = Data([0x03] + Array(repeating: 0x44, count: 32))
        func edge(_ id: String, _ key: Data, _ status: Spark_TransferReceiverStatus = .keyTweaked) -> Spark_TransferReceiver {
            var receiver = Spark_TransferReceiver()
            receiver.id = id
            receiver.identityPublicKey = key
            receiver.status = status
            return receiver
        }
        var mine = try leaf(id: "leaf-a", transferId: id, cipher: Data(repeating: 1, count: 40), signWith: sender)
        mine.transferReceiverID = "edge-me"
        var theirs = try leaf(id: "leaf-b", transferId: id, cipher: Data(repeating: 2, count: 40), signWith: sender)
        theirs.transferReceiverID = "edge-other"
        var split = transfer([mine, theirs], id: id)
        // The operators record the lowest receiver key, which is not this wallet's.
        split.receiverIdentityPublicKey = other
        split.receivers = [edge("edge-other", other), edge("edge-me", receiver.identityPublicKey)]

        let scoped = try TransferLeafVerifier.scoped(split, toReceiver: receiver.identityPublicKey)
        #expect(scoped.leaves.map(\.leaf.id) == ["leaf-a"])
        try TransferLeafVerifier.verify(transfer: scoped, receiverIdentityPublicKey: receiver.identityPublicKey)

        // Not among the receivers, or no leaves on this wallet's edge.
        #expect(throws: SparkError.self) { _ = try TransferLeafVerifier.scoped(split, toReceiver: self.sender.identityPublicKey) }
        var unassigned = split
        unassigned.leaves = [theirs]
        #expect(throws: SparkError.self) { _ = try TransferLeafVerifier.scoped(unassigned, toReceiver: self.receiver.identityPublicKey) }
        // A single-receiver transfer is not narrowed.
        let single = transfer([mine], id: id)
        #expect(try TransferLeafVerifier.scoped(single, toReceiver: receiver.identityPublicKey) == single)

        // This wallet's leg completes with its own edge, before the whole transfer does.
        #expect(!TransferLeafVerifier.isReceiverLegComplete(split, receiverIdentityPublicKey: receiver.identityPublicKey))
        var legDone = split
        legDone.receivers = [edge("edge-other", other), edge("edge-me", receiver.identityPublicKey, .completed)]
        #expect(TransferLeafVerifier.isReceiverLegComplete(legDone, receiverIdentityPublicKey: receiver.identityPublicKey))
        #expect(!TransferLeafVerifier.isReceiverLegComplete(legDone, receiverIdentityPublicKey: other))
        var whole = single
        whole.status = .completed
        #expect(TransferLeafVerifier.isReceiverLegComplete(whole, receiverIdentityPublicKey: receiver.identityPublicKey))
        #expect(!TransferLeafVerifier.isReceiverLegComplete(single, receiverIdentityPublicKey: receiver.identityPublicKey))
    }

    @Test("A transfer is looked up by id with the operators' by-id query", .timeLimit(.minutes(1)))
    func lookupById() async throws {
        let state = FakeOperatorState { _ in false }
        var known = Spark_Transfer()
        known.id = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        known.totalValue = 42
        known.status = .completed
        await state.know(known)
        try await withFakeOperator(state) { wallet in
            let transfer = try await wallet.getTransfer(id: known.id.uppercased())
            #expect(transfer.id == known.id)
            #expect(transfer.totalValueSats == 42)
            await #expect(throws: SparkError.self) { _ = try await wallet.getTransfer(id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c") }
        }
        #expect(await state.methods == ["query_transfers_by_id", "query_transfers_by_id"])
    }
}
