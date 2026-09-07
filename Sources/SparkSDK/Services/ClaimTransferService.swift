import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

// Constants defined in KeyTweakHelper.swift

extension SparkWallet {
    /// Query pending transfers where this wallet is the receiver
    func queryPendingTransfers() async throws -> [Spark_Transfer] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var filter = Spark_TransferFilter()
        filter.receiverIdentityPublicKey = signer.identityPublicKey
        filter.network = config.networkProto

        let response = try await client.query_pending_transfers(
            request: ClientRequest(message: filter, metadata: metadata)
        )
        return response.transfers
    }

    /// Claim all pending transfers (lightning receives, spark transfers)
    public func claimAllPendingTransfers() async throws -> Int {
        let transfers = try await queryPendingTransfers()
        var claimed = 0
        for transfer in transfers {
            try await claimTransfer(transfer)
            claimed += 1
        }
        return claimed
    }

    /// Claim a single pending transfer using the single-call claim_transfer with ClaimPackage
    func claimTransfer(_ transfer: Spark_Transfer) async throws {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let soOperators = soListResponse.signingOperators
        let soCount = UInt32(soOperators.count)
        let threshold = max(2, (soCount + 2) / 2)

        let transferLeaves = transfer.leaves

        // Get signing commitments (Count=3: cpfp, direct, directFromCpfp)
        var commitmentsRequest = Spark_GetSigningCommitmentsRequest()
        commitmentsRequest.count = 3
        commitmentsRequest.nodeIDCount = UInt32(transferLeaves.count)
        let commitmentsResponse = try await client.get_signing_commitments(
            request: ClientRequest(message: commitmentsRequest, metadata: metadata)
        )
        let allCommitments = commitmentsResponse.signingCommitments

        var cpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []
        var directRefundJobs: [Spark_UserSignedTxSigningJob] = []
        var directFromCpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []

        var perSoTweaks: [String: Spark_ClaimLeafKeyTweaks] = [:]
        for soID in soOperators.keys {
            perSoTweaks[soID] = Spark_ClaimLeafKeyTweaks()
        }

        for i in 0..<transferLeaves.count {
            let transferLeaf = transferLeaves[i]
            let node = transferLeaf.leaf

            // ECIES decrypt secret_cipher → sender's intermediate signing key (oldKey)
            let oldSigningKey = try decryptEcies(
                encryptedMsg: transferLeaf.secretCipher,
                privateKey: signer.deriveIdentityPrivateKey()
            )

            // Derive new signing key for this leaf
            let newSigningKey = try signer.deriveLeafSigningKey(node.id)
            let newSigningPubKey = try getPublicKeyBytes(privateKeyBytes: newSigningKey, compressed: true)
            let verifyingKey = Data(node.verifyingPublicKey)

            // Compute key tweak = oldKey - newKey (mod secp256k1 order)
            let keyTweak = try subtractPrivateKeys(oldSigningKey, newSigningKey)

            // VSS split the tweak among SOs
            let vssShares = try splitSecretWithProofsUniffi(
                secret: keyTweak, threshold: threshold, numShares: soCount
            )

            // Get sequence from intermediate refund tx (matching JS SDK: uses intermediateRefundTx)
            let intermediateRefundTx = Data(transferLeaf.intermediateRefundTx)
            let nodeRefundTx = Data(node.refundTx)
            let rawSequence: UInt32
            if !intermediateRefundTx.isEmpty {
                rawSequence = try Self.parseSequenceFromRawTx(intermediateRefundTx)
            } else if !nodeRefundTx.isEmpty {
                rawSequence = try Self.parseSequenceFromRawTx(nodeRefundTx)
            } else {
                rawSequence = try Self.parseSequenceFromRawTx(Data(node.nodeTx))
            }

            // Enforce timelocks: round down to nearest interval (matching JS SDK)
            var currentTimelock = rawSequence & 0xFFFF
            let remainder = currentTimelock % sparkTimeLockInterval
            if remainder != 0 {
                currentTimelock = currentTimelock - remainder
            }
            let bit30 = rawSequence & (1 << 30)
            let cpfpSequence = bit30 | (currentTimelock & 0xFFFF)
            let directSequence = bit30 | ((currentTimelock + sparkDirectTimelockOffset) & 0xFFFF)

            // Construct refund tx trio
            let cpfpNodeTx = Data(node.nodeTx)
            let directNodeTx = node.directTx.isEmpty ? nil : Data(node.directTx)

            let refundTrio = try constructRefundTxTrio(
                cpfpNodeTx: cpfpNodeTx,
                directNodeTx: directNodeTx,
                vout: 0,
                receivingPubkey: newSigningPubKey,
                network: networkStr,
                sequence: cpfpSequence,
                directSequence: directSequence,
                feeSats: sparkDefaultFeeSats
            )

            // Commitments interleaved: [leaf0_r0, leaf1_r0, ..., leaf0_r1, ...]
            let cpfpCommitments = allCommitments[i].signingNonceCommitments
            let directCommitments = allCommitments[i + transferLeaves.count].signingNonceCommitments
            let directFromCpfpCommitments = allCommitments[i + 2 * transferLeaves.count].signingNonceCommitments

            cpfpRefundJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: node.id, signingKey: newSigningKey, verifyingKey: verifyingKey,
                rawTx: refundTrio.cpfpRefund.tx, sighash: refundTrio.cpfpRefund.sighash,
                soCommitments: cpfpCommitments
            ))

            if let directRefund = refundTrio.directRefund {
                directRefundJobs.append(try FrostSigningHelper.buildSigningJob(
                    leafID: node.id, signingKey: newSigningKey, verifyingKey: verifyingKey,
                    rawTx: directRefund.tx, sighash: directRefund.sighash,
                    soCommitments: directCommitments
                ))
            }

            directFromCpfpRefundJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: node.id, signingKey: newSigningKey, verifyingKey: verifyingKey,
                rawTx: refundTrio.directFromCpfpRefund.tx, sighash: refundTrio.directFromCpfpRefund.sighash,
                soCommitments: directFromCpfpCommitments
            ))

            // Build pubkey shares tweak map
            var pubkeyBySOID: [String: Data] = [:]
            for (soID, soInfo) in soOperators {
                let matchedShare = vssShares.first { $0.index == soInfo.index + 1 }!
                pubkeyBySOID[soID] = try getPublicKeyBytes(privateKeyBytes: matchedShare.share, compressed: true)
            }

            // Build per-SO key tweak entries
            for (soID, soInfo) in soOperators {
                let share = vssShares.first { $0.index == soInfo.index + 1 }!

                var secretShareProto = Spark_SecretShare()
                secretShareProto.secretShare = share.share
                for proof in share.proofs {
                    secretShareProto.proofs.append(proof)
                }

                var leafTweak = Spark_ClaimLeafKeyTweak()
                leafTweak.leafID = node.id
                leafTweak.secretShareTweak = secretShareProto
                for (otherSoID, pubkey) in pubkeyBySOID {
                    leafTweak.pubkeySharesTweak[otherSoID] = pubkey
                }

                perSoTweaks[soID]?.leavesToReceive.append(leafTweak)
            }
        }

        let claimPackageResult = try KeyTweakHelper.encryptAndSign(
            transferID: transfer.id,
            perSoTweaks: perSoTweaks,
            soOperators: soOperators,
            signingOperatorConfigs: config.signingOperators,
            signer: signer,
            tag: "claim"
        )
        let keyTweakPackage = claimPackageResult.keyTweakPackage
        let packageSignature = claimPackageResult.signature

        // Build ClaimPackage
        var claimPackage = Spark_ClaimPackage()
        claimPackage.userSignature = packageSignature
        claimPackage.hashVariant = .v2
        claimPackage.leavesToClaim = cpfpRefundJobs
        claimPackage.directLeavesToClaim = directRefundJobs
        claimPackage.directFromCpfpLeavesToClaim = directFromCpfpRefundJobs
        for (soID, cipher) in keyTweakPackage {
            claimPackage.keyTweakPackage[soID] = cipher
        }

        // Call claim_transfer
        var claimRequest = Spark_ClaimTransferRequest()
        claimRequest.transferID = transfer.id
        claimRequest.ownerIdentityPublicKey = signer.identityPublicKey
        claimRequest.claimPackage = claimPackage

        let _ = try await client.claim_transfer(
            request: ClientRequest(message: claimRequest, metadata: metadata)
        )
    }
}
