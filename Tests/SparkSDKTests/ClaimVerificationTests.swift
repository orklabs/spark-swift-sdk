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
}
