import Foundation
import CryptoKit
import secp256k1

/// Authenticates the leaves of a pending inbound transfer before the wallet decrypts the leaf
/// secrets, derives tweaks, or signs refund transactions. Mirrors the reference SDK's
/// `verifyPendingTransfer`: each leaf carries the sender's signature over
/// `sha256(leafId || transferId || secretCipher)`, made with the sender's identity key — a legacy
/// ECDSA signature or a scheme-tagged one.
enum TransferLeafVerifier {

    static func payloadHash(leafId: String, transferId: String, secretCipher: Data) -> Data {
        var payload = Data(leafId.utf8)
        payload.append(Data(transferId.utf8))
        payload.append(secretCipher)
        return Data(CryptoKit.SHA256.hash(data: payload))
    }

    /// ECDSA verification over a 32-byte digest with a 33-byte compressed public key.
    /// Accepts the 64-byte compact form (what this SDK produces) and DER. Malformed input is an
    /// invalid signature, never a crash.
    static func verifyECDSA(signature: Data, digest: Data, compressedPublicKey: Data) -> Bool {
        guard digest.count == 32, compressedPublicKey.count == 33,
              compressedPublicKey.first == 0x02 || compressedPublicKey.first == 0x03,
              !signature.isEmpty else {
            return false
        }
        do {
            let publicKey = try secp256k1.Signing.PublicKey(dataRepresentation: compressedPublicKey, format: .compressed)
            let parsed: secp256k1.Signing.ECDSASignature
            if signature.count == 64 {
                parsed = try secp256k1.Signing.ECDSASignature(compactRepresentation: signature)
            } else {
                parsed = try secp256k1.Signing.ECDSASignature(derRepresentation: signature)
            }
            return publicKey.isValidSignature(parsed, for: HashDigest(Array(digest)))
        } catch {
            return false
        }
    }

    /// A leaf's sender signature, the reference SDK's `verifyTypedSignature`: the legacy field is
    /// ECDSA in either encoding (senders emit compact or DER); a typed signature is verified by its
    /// scheme — ECDSA in strict DER only, BIP-340 Schnorr against the x-only form of the key — and
    /// an unspecified or unknown scheme, a missing signature, a key that is not 33-byte compressed
    /// or a digest that is not 32 bytes is refused.
    static func verifySenderSignature(_ sig: Spark_TransferLeaf.OneOf_Sig?, digest: Data, compressedPublicKey: Data) -> Bool {
        guard digest.count == 32, compressedPublicKey.count == 33,
              compressedPublicKey.first == 0x02 || compressedPublicKey.first == 0x03 else {
            return false
        }
        switch sig {
        case .signature(let legacy)?:
            return verifyECDSA(signature: legacy, digest: digest, compressedPublicKey: compressedPublicKey)
        case .typedSignature(let typed)?:
            guard !typed.signature.isEmpty else { return false }
            switch typed.scheme {
            case .ecdsa:
                guard let publicKey = try? secp256k1.Signing.PublicKey(dataRepresentation: compressedPublicKey, format: .compressed),
                      let parsed = try? secp256k1.Signing.ECDSASignature(derRepresentation: typed.signature) else {
                    return false
                }
                return publicKey.isValidSignature(parsed, for: HashDigest(Array(digest)))
            case .schnorr:
                guard typed.signature.count == 64,
                      let signature = try? secp256k1.Schnorr.SchnorrSignature(dataRepresentation: typed.signature) else {
                    return false
                }
                var message = [UInt8](digest)
                return secp256k1.Schnorr.XonlyKey(dataRepresentation: compressedPublicKey.dropFirst())
                    .isValid(signature, for: &message)
            default:
                return false
            }
        case nil:
            return false
        }
    }

    /// Throws `SparkError.untrustedResponse` unless every leaf is present and carries a valid
    /// sender signature, and the transfer is addressed to `receiverIdentityPublicKey`.
    static func verify(transfer: Spark_Transfer, receiverIdentityPublicKey: Data) throws {
        guard transfer.receiverIdentityPublicKey == receiverIdentityPublicKey else {
            throw SparkError.untrustedResponse("transfer \(transfer.id) is not addressed to this wallet")
        }
        guard !transfer.leaves.isEmpty else {
            throw SparkError.untrustedResponse("transfer \(transfer.id) has no leaves")
        }
        for transferLeaf in transfer.leaves {
            guard transferLeaf.hasLeaf, !transferLeaf.leaf.id.isEmpty else {
                throw SparkError.untrustedResponse("transfer \(transfer.id) contains a leaf without node data")
            }
            guard !transferLeaf.secretCipher.isEmpty else {
                throw SparkError.untrustedResponse("leaf \(transferLeaf.leaf.id) in transfer \(transfer.id) has no secret cipher")
            }
            let digest = payloadHash(leafId: transferLeaf.leaf.id, transferId: transfer.id, secretCipher: transferLeaf.secretCipher)
            guard verifySenderSignature(
                transferLeaf.sig, digest: digest, compressedPublicKey: transfer.senderIdentityPublicKey
            ) else {
                throw SparkError.untrustedResponse(
                    "sender signature on leaf \(transferLeaf.leaf.id) in transfer \(transfer.id) is missing or invalid"
                )
            }
        }
    }
}
