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

    /// One operator as the coordinator lists it, reconciled with the wallet configuration.
    struct OperatorTarget: Equatable {
        let soID: String
        /// 1-based VSS share index (the coordinator's 0-based `index` + 1).
        let shareIndex: UInt32
        /// Identity key from the wallet configuration — never from the coordinator.
        let identityPublicKey: Data
    }

    /// Reconcile the coordinator's operator list with the configured operators. Every listed
    /// operator must be configured, the sets must be the same size, and the indices must be a
    /// permutation of 0..<n. Secret shares are only ever encrypted to configured keys.
    static func matchOperators(
        server: [String: Spark_SigningOperatorInfo],
        config: [SigningOperatorConfig]
    ) throws -> [OperatorTarget] {
        guard !server.isEmpty else {
            throw SparkError.untrustedResponse("coordinator returned an empty signing operator list")
        }
        guard server.count == config.count else {
            throw SparkError.untrustedResponse(
                "coordinator lists \(server.count) signing operators, wallet is configured for \(config.count)"
            )
        }
        var targets: [OperatorTarget] = []
        var seenIndices = Set<UInt64>()
        for (soID, info) in server {
            guard let operatorConfig = config.first(where: { $0.identifier == soID }) else {
                throw SparkError.untrustedResponse("coordinator listed operator \(soID) which is not in the wallet configuration")
            }
            guard info.index < UInt64(config.count), seenIndices.insert(info.index).inserted else {
                throw SparkError.untrustedResponse("coordinator reported an invalid or duplicate index \(info.index) for operator \(soID)")
            }
            guard let key = Data(hexString: operatorConfig.identityPublicKeyHex), key.count == 33 else {
                throw SparkError.invalidArgument("operator \(soID) has no valid identity public key configured")
            }
            targets.append(OperatorTarget(soID: soID, shareIndex: UInt32(info.index) + 1, identityPublicKey: key))
        }
        return targets.sorted { $0.shareIndex < $1.shareIndex }
    }

    /// Build and encrypt a key tweak package for sending leaves to a receiver.
    /// Used by TransferService, LightningService, WithdrawalService, and SwapService.
    static func buildSendPackage(
        transferID: String,
        leaves: [SparkLeaf],
        receiverPubKey: Data,
        signer: SparkSignerProtocol,
        soOperators: [String: Spark_SigningOperatorInfo],
        signingOperatorConfigs: [SigningOperatorConfig],
        threshold: UInt32
    ) throws -> (perSoTweaks: [String: Spark_SendLeafKeyTweaks], package: Package) {
        let targets = try matchOperators(server: soOperators, config: signingOperatorConfigs)
        let soCount = UInt32(targets.count)
        guard threshold >= 1, threshold <= soCount else {
            throw SparkError.invalidArgument("signing threshold \(threshold) is not valid for \(soCount) operators")
        }

        var perSoTweaks: [String: Spark_SendLeafKeyTweaks] = [:]
        for target in targets {
            perSoTweaks[target.soID] = Spark_SendLeafKeyTweaks()
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

            let sharesByTarget = try shares(vssShares, for: targets)
            var pubkeyBySOID: [String: Data] = [:]
            for (target, share) in sharesByTarget {
                pubkeyBySOID[target.soID] = try getPublicKeyBytes(privateKeyBytes: share.share, compressed: true)
            }

            for (target, share) in sharesByTarget {
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
                perSoTweaks[target.soID]?.leavesToSend.append(leafTweak)
            }
        }

        let package = try encryptAndSign(
            transferID: transferID,
            perSoTweaks: perSoTweaks,
            targets: targets,
            signer: signer,
            tag: "transfer"
        )

        return (perSoTweaks, package)
    }

    /// Pair each operator with its VSS share by share index, in target order.
    static func shares(
        _ vssShares: [VerifiableSecretShareResult],
        for targets: [OperatorTarget]
    ) throws -> [(target: OperatorTarget, share: VerifiableSecretShareResult)] {
        try targets.map { target in
            guard let share = vssShares.first(where: { $0.index == target.shareIndex }) else {
                throw SparkError.frostSigningFailed("no secret share produced for operator \(target.soID) (index \(target.shareIndex))")
            }
            return (target, share)
        }
    }

    /// Encrypt per-SO tweak data to each operator's configured identity key and sign the package.
    static func encryptAndSign<T: SwiftProtobuf.Message>(
        transferID: String,
        perSoTweaks: [String: T],
        targets: [OperatorTarget],
        signer: SparkSignerProtocol,
        tag: String
    ) throws -> Package {
        var keyTweakPackage: [String: Data] = [:]
        for target in targets {
            guard let tweaks = perSoTweaks[target.soID] else {
                throw SparkError.frostSigningFailed("no key tweaks prepared for operator \(target.soID)")
            }
            let tweaksBytes = try tweaks.serializedData()
            keyTweakPackage[target.soID] = try encryptEcies(msg: tweaksBytes, publicKey: target.identityPublicKey)
        }

        guard let transferIdBytes = Data(hexString: transferID.replacingOccurrences(of: "-", with: "")),
              transferIdBytes.count == 16 else {
            throw SparkError.invalidArgument("transfer id '\(transferID)' is not a UUID")
        }
        var hasher = SparkHasher(tag: ["spark", tag, "signing payload"])
        hasher.addBytes(transferIdBytes)
        hasher.addMapStringToBytes(keyTweakPackage)
        let packagePayload = hasher.hash()
        let packageSignature = try signer.signWithIdentityKey(packagePayload)

        return Package(keyTweakPackage: keyTweakPackage, signature: packageSignature)
    }
}
