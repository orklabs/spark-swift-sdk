import Foundation
import CryptoKit
import Testing
import secp256k1
@testable import SparkSDK

/// The reference SDK's `verifyTypedSignature` tests (`signature.test.ts`), with its keys and
/// digest. Its two cases where both a legacy and a typed signature are present cannot arise
/// here: the generated oneof holds one or the other.
@Suite("Leaf sender signatures")
struct LeafSignatureTests {
    static let signer = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let other = "0000000000000000000000000000000000000000000000000000000000000007"
    static let digest = Data(SHA256.hash(data: Data("leaf-id:transfer-id:cipher".utf8)))

    static func privateKey(_ hex: String) throws -> secp256k1.Signing.PrivateKey {
        guard let bytes = Data(hexString: hex) else { throw SparkError.invalidArgument("bad key hex") }
        return try secp256k1.Signing.PrivateKey(dataRepresentation: bytes)
    }

    static func publicKey(_ hex: String = signer) throws -> Data {
        try privateKey(hex).publicKey.dataRepresentation
    }

    static func ecdsa(_ digest: Data = digest, key hex: String = signer) throws -> secp256k1.Signing.ECDSASignature {
        try privateKey(hex).signature(for: HashDigest(Array(digest)))
    }

    static func schnorr(_ digest: Data = digest, key hex: String = signer) throws -> Data {
        let signer = try secp256k1.Schnorr.PrivateKey(dataRepresentation: try privateKey(hex).dataRepresentation)
        return try signer.signature(for: HashDigest(Array(digest))).dataRepresentation
    }

    static func typed(_ scheme: Common_SignatureScheme, _ signature: Data) -> Spark_TransferLeaf.OneOf_Sig {
        var typed = Common_Signature()
        typed.scheme = scheme
        typed.signature = signature
        return .typedSignature(typed)
    }

    static func verify(_ sig: Spark_TransferLeaf.OneOf_Sig?, digest: Data = digest, key: Data? = nil) throws -> Bool {
        TransferLeafVerifier.verifySenderSignature(sig, digest: digest, compressedPublicKey: try key ?? publicKey())
    }

    @Test("Legacy ECDSA signatures verify in compact and DER encoding, and only for the signer's key")
    func legacy() throws {
        #expect(try Self.verify(.signature(try Self.ecdsa().compactRepresentation)))
        #expect(try Self.verify(.signature(try Self.ecdsa().derRepresentation)))
        #expect(try !Self.verify(.signature(try Self.ecdsa(key: Self.other).compactRepresentation)))
    }

    @Test("A typed ECDSA signature must be strict DER")
    func typedECDSA() throws {
        #expect(try Self.verify(Self.typed(.ecdsa, try Self.ecdsa().derRepresentation)))
        #expect(try !Self.verify(Self.typed(.ecdsa, try Self.ecdsa().compactRepresentation)))
    }

    @Test("A typed Schnorr signature verifies against the compressed key's x-only form")
    func typedSchnorr() throws {
        #expect(try Self.verify(Self.typed(.schnorr, try Self.schnorr())))
        #expect(try !Self.verify(Self.typed(.schnorr, try Self.schnorr()), key: try Self.publicKey(Self.other)))
    }

    @Test("A signature labelled with the other scheme is refused")
    func mislabelled() throws {
        #expect(try !Self.verify(Self.typed(.schnorr, try Self.ecdsa().compactRepresentation)))
        #expect(try !Self.verify(Self.typed(.ecdsa, try Self.schnorr())))
    }

    @Test("An unspecified or unrecognised scheme, or no signature at all, is refused")
    func failClosed() throws {
        #expect(try !Self.verify(Self.typed(.unspecified, try Self.ecdsa().derRepresentation)))
        #expect(try !Self.verify(Self.typed(.UNRECOGNIZED(9), try Self.ecdsa().derRepresentation)))
        #expect(try !Self.verify(nil))
        #expect(try !Self.verify(Self.typed(.ecdsa, Data())))
        #expect(try !Self.verify(.signature(Data())))
    }

    @Test("A valid signature over another digest, or malformed bytes, is refused without throwing")
    func wrongDigestAndMalformed() throws {
        let other = Data(SHA256.hash(data: Data("something else".utf8)))
        #expect(try !Self.verify(.signature(try Self.ecdsa(other).compactRepresentation)))
        #expect(try !Self.verify(Self.typed(.schnorr, try Self.schnorr(other))))
        #expect(try !Self.verify(.signature(Data([1, 2, 3]))))
        #expect(try !Self.verify(Self.typed(.ecdsa, Data([0x30, 0x02, 0x01]))))
        #expect(try !Self.verify(Self.typed(.schnorr, Data(repeating: 0xFF, count: 64))))
    }

    @Test("Only a 33-byte compressed key and a 32-byte digest are accepted, on every path")
    func keyAndDigestShapes() throws {
        let uncompressed = try getPublicKeyBytes(privateKeyBytes: try Self.privateKey(Self.signer).dataRepresentation, compressed: false)
        #expect(uncompressed.count == 65)
        #expect(try !Self.verify(Self.typed(.ecdsa, try Self.ecdsa().derRepresentation), key: uncompressed))
        #expect(try !Self.verify(.signature(try Self.ecdsa().compactRepresentation), key: uncompressed))
        #expect(try !Self.verify(Self.typed(.schnorr, try Self.schnorr()), key: try Self.publicKey().dropFirst()))
        var badPrefix = try Self.publicKey()
        badPrefix[0] = 0x05
        #expect(try !Self.verify(Self.typed(.schnorr, try Self.schnorr()), key: badPrefix))
        // A 33-byte digest whose first 32 bytes the signature covers is still refused.
        #expect(try !Self.verify(.signature(try Self.ecdsa().compactRepresentation), digest: Self.digest + Data([0])))
    }

    @Test("A transfer whose leaves carry typed signatures is verified before it is claimed")
    func typedTransfer() throws {
        let receiver = try secp256k1.Signing.PrivateKey().publicKey.dataRepresentation
        var transfer = Spark_Transfer()
        transfer.id = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        transfer.senderIdentityPublicKey = try Self.publicKey()
        transfer.receiverIdentityPublicKey = receiver
        var leaf = Spark_TransferLeaf()
        leaf.leaf.id = "leaf-a"
        leaf.secretCipher = Data(repeating: 7, count: 40)
        let digest = TransferLeafVerifier.payloadHash(leafId: "leaf-a", transferId: transfer.id, secretCipher: leaf.secretCipher)
        leaf.sig = Self.typed(.schnorr, try Self.schnorr(digest))
        transfer.leaves = [leaf]
        try TransferLeafVerifier.verify(transfer: transfer, receiverIdentityPublicKey: receiver)

        transfer.leaves[0].sig = Self.typed(.schnorr, try Self.schnorr(digest, key: Self.other))
        #expect(throws: SparkError.self) { try TransferLeafVerifier.verify(transfer: transfer, receiverIdentityPublicKey: receiver) }
    }
}
