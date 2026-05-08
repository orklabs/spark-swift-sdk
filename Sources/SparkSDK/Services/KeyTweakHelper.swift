import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

// MARK: - Shared constants (matching JS SDK / Go server)

let sparkTimeLockInterval: UInt32 = 100
let sparkDirectTimelockOffset: UInt32 = 50
let sparkDefaultFeeSats: UInt64 = 191 * 5

// MARK: - Key tweak package builder

/// Shared logic for building encrypted key tweak packages used in transfers, swaps, and withdrawals.
enum KeyTweakHelper {

    struct Package {
        let keyTweakPackage: [String: Data]
        let signature: Data
    }

    /// Build and encrypt a key tweak package for sending leaves to a receiver.
    /// Used by TransferService, LightningService, WithdrawalService, and SwapService.
    static func buildSendPackage(
        transferID: String,
        leaves: [SparkLeaf],
        receiverPubKey: Data,
        signer: SparkSignerProtocol,
        soOperators: [String: Spark_SigningOperatorInfo],
        signingOperatorConfigs: [SigningOperatorConfig]
    ) throws -> (perSoTweaks: [String: Spark_SendLeafKeyTweaks], package: Package) {
        let soCount = UInt32(soOperators.count)
        let threshold = max(2, (soCount + 2) / 2)

        var perSoTweaks: [String: Spark_SendLeafKeyTweaks] = [:]
        for soID in soOperators.keys {
            perSoTweaks[soID] = Spark_SendLeafKeyTweaks()
        }

        for leaf in leaves {
            let oldSigningKey = try signer.deriveLeafSigningKey(leaf.id)
            let newRandomKey = try randomSecretKeyBytes()
            let keyTweak = try subtractPrivateKeys(oldSigningKey, newRandomKey)
            let vssShares = try splitSecretWithProofsUniffi(
                secret: keyTweak, threshold: threshold, numShares: soCount
            )
            let secretCipher = try encryptEcies(msg: newRandomKey, publicKey: receiverPubKey)

            var sigPayload = Data(leaf.id.utf8)
            sigPayload.append(Data(transferID.utf8))
            sigPayload.append(secretCipher)
            let tweakSig = try signer.signCompactWithIdentityKey(Data(CryptoKit.SHA256.hash(data: sigPayload)))

            var pubkeyBySOID: [String: Data] = [:]
            for (soID, soInfo) in soOperators {
                let matchedShare = vssShares.first { $0.index == soInfo.index + 1 }!
                pubkeyBySOID[soID] = try getPublicKeyBytes(privateKeyBytes: matchedShare.share, compressed: true)
            }

            for (soID, soInfo) in soOperators {
                let share = vssShares.first { $0.index == soInfo.index + 1 }!
                var secretShareProto = Spark_SecretShare()
                secretShareProto.secretShare = share.share
                for proof in share.proofs {
                    secretShareProto.proofs.append(proof)
                }
                var leafTweak = Spark_SendLeafKeyTweak()
                leafTweak.leafID = leaf.id
                leafTweak.secretShareTweak = secretShareProto
                leafTweak.secretCipher = secretCipher
                leafTweak.signature = tweakSig
                for (otherSoID, pubkey) in pubkeyBySOID {
                    leafTweak.pubkeySharesTweak[otherSoID] = pubkey
                }
                perSoTweaks[soID]?.leavesToSend.append(leafTweak)
            }
        }

        let package = try encryptAndSign(
            transferID: transferID,
            perSoTweaks: perSoTweaks,
            soOperators: soOperators,
            signingOperatorConfigs: signingOperatorConfigs,
            signer: signer,
            tag: "transfer"
        )

        return (perSoTweaks, package)
    }

    /// Encrypt per-SO tweak data and sign the package.
    static func encryptAndSign<T: SwiftProtobuf.Message>(
        transferID: String,
        perSoTweaks: [String: T],
        soOperators: [String: Spark_SigningOperatorInfo],
        signingOperatorConfigs: [SigningOperatorConfig],
        signer: SparkSignerProtocol,
        tag: String
    ) throws -> Package {
        var keyTweakPackage: [String: Data] = [:]
        for soID in soOperators.keys {
            let tweaksBytes = try perSoTweaks[soID]!.serializedData()
            let soConfig = signingOperatorConfigs.first { $0.identifier == soID }!
            let identityPubKey = Data(hexString: soConfig.identityPublicKeyHex)!
            let encrypted = try encryptEcies(msg: tweaksBytes, publicKey: identityPubKey)
            keyTweakPackage[soID] = encrypted
        }

        let transferIdBytes = Data(hexString: transferID.replacingOccurrences(of: "-", with: ""))!
        var hasher = SparkHasher(tag: ["spark", tag, "signing payload"])
        hasher.addBytes(transferIdBytes)
        hasher.addMapStringToBytes(keyTweakPackage)
        let packagePayload = hasher.hash()
        let packageSignature = try signer.signWithIdentityKey(packagePayload)

        return Package(keyTweakPackage: keyTweakPackage, signature: packageSignature)
    }
}
