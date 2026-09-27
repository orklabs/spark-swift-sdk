import Foundation
import CryptoKit
import secp256k1

/// Checks a deposit address the coordinator generated before the wallet hands it to anyone, as
/// the reference SDK does (`DepositService.validateDepositAddress`). Without these checks a
/// coordinator — or anyone impersonating it — could hand out an address it alone controls; a
/// static address is reused for every deposit.
///
/// - The proof of possession: a BIP-340 signature by the operators' share of the key
///   (verifying key minus the wallet's signing key, BIP-86 tweaked) over the tagged hash
///   `["spark", "deposit", "proof_of_possession"]` of the wallet's identity key, that operator
///   key and the address (`ProofOfPossessionMessageHashForDepositAddress`, hash variant V2).
/// - Every operator's ECDSA signature over sha256(address), by its configured identity key. The
///   coordinator's own signature is required for static addresses only.
/// - The address pays P2TR of the verifying key (`P2TRAddressFromPublicKey`), so the proof
///   covers the key the funds actually go to.
enum DepositAddressVerifier {
    /// `config` supplies the operators (their identifiers and identity keys, the first one being
    /// the coordinator) and the network.
    static func verify(
        _ address: Spark_Address,
        userSigningPublicKey: Data,
        identityPublicKey: Data,
        isStatic: Bool,
        config: SparkConfig
    ) throws {
        let proof = address.depositAddressProof
        guard address.hasDepositAddressProof, !proof.proofOfPossessionSignature.isEmpty, !proof.addressSignatures.isEmpty else {
            throw SparkError.untrustedResponse(
                "deposit address \(address.address) comes without a proof of possession and operator signatures"
            )
        }
        let verifyingKey = Data(address.verifyingKey)
        guard (try? SparkWallet.leafNodeAddress(verifyingKey: verifyingKey, network: config.network)) == address.address else {
            throw SparkError.untrustedResponse("deposit address \(address.address) does not pay the reported verifying key")
        }

        let operatorPublicKey = try subtractPublicKeys(verifyingKey, userSigningPublicKey)
        var hasher = SparkHasher(tag: ["spark", "deposit", "proof_of_possession"])
        hasher.addBytes(identityPublicKey)
        hasher.addBytes(operatorPublicKey)
        hasher.addBytes(Data(address.address.utf8))
        guard verifySchnorr(
            signature: Data(proof.proofOfPossessionSignature),
            message: hasher.hash(),
            taprootInternalKey: operatorPublicKey
        ) else {
            throw SparkError.untrustedResponse("deposit address \(address.address) has an invalid proof of possession")
        }

        let addressHash = Data(SHA256.hash(data: Data(address.address.utf8)))
        let coordinatorIdentifier = config.signingOperators.first?.identifier
        for signingOperator in config.signingOperators where isStatic || signingOperator.identifier != coordinatorIdentifier {
            guard let signature = proof.addressSignatures[signingOperator.identifier],
                  let operatorKey = Data(hexString: signingOperator.identityPublicKeyHex),
                  TransferLeafVerifier.verifyECDSA(signature: signature, digest: addressHash, compressedPublicKey: operatorKey) else {
                throw SparkError.untrustedResponse(
                    "deposit address \(address.address) lacks a valid signature from operator \(signingOperator.identifier)"
                )
            }
        }
    }

    /// `a - b` for two compressed secp256k1 public keys.
    static func subtractPublicKeys(_ a: Data, _ b: Data) throws -> Data {
        do {
            let lhs = try secp256k1.Signing.PublicKey(dataRepresentation: a, format: .compressed)
            let rhs = try secp256k1.Signing.PublicKey(dataRepresentation: b, format: .compressed)
            return try lhs.combine([try rhs.negation]).dataRepresentation
        } catch {
            throw SparkError.untrustedResponse("invalid deposit address key material")
        }
    }

    /// BIP-340 verification of `signature` over the 32-byte `message` under the BIP-86 output key
    /// of `taprootInternalKey`.
    static func verifySchnorr(signature: Data, message: Data, taprootInternalKey: Data) -> Bool {
        guard signature.count == 64, message.count == 32,
              let tweaked = try? getTaprootPubkey(verifyingPubkey: taprootInternalKey), tweaked.count == 33,
              let schnorrSignature = try? secp256k1.Schnorr.SchnorrSignature(dataRepresentation: signature) else {
            return false
        }
        let key = secp256k1.Schnorr.XonlyKey(dataRepresentation: tweaked.dropFirst())
        var bytes = [UInt8](message)
        return key.isValid(schnorrSignature, for: &bytes)
    }
}
