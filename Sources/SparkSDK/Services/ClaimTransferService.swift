import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

// Constants defined in KeyTweakHelper.swift

/// The outcome of one pass over the wallet's pending inbound transfers.
public struct PendingTransferClaim: Sendable {
    /// Transfers claimed in this pass, in the order they were claimed.
    public let claimedTransferIds: [String]
    /// Transfers that could not be claimed. They stay pending and are tried again on the next
    /// pass. One the SDK refuses to claim (for example because a sender signature does not
    /// verify) fails every time, but never stops the others from being claimed.
    public let failures: [Failure]

    public struct Failure: Sendable {
        public let transferId: String
        public let error: any Swift.Error
    }

    /// The claimed transfers, as they were claimed.
    var claimedTransfers: [Spark_Transfer] = []

    /// Leaves of the claimed transfers.
    var claimedLeafIds: [String] {
        claimedTransfers.flatMap { $0.leaves.map(\.leaf.id) }
    }
}

/// One claim pass over the pending inbound transfers, following the reference SDK's
/// `claimTransfers`: pages of 25, only transfers in a claimable status, a failure is recorded and
/// the pass moves on, and after any progress it restarts from the head (claimed transfers leave
/// the pending set, shifting later ones forward); otherwise it advances past the page. Without a
/// server-time snapshot the pass is bounded to 100 pages, as the reference SDK's fallback is. A
/// transfer that failed is not tried again within the same pass.
enum PendingTransferDrain {
    static let batchSize = 25
    static let maxBatches = 100
    /// Statuses the reference SDK claims; anything else is left for a later pass.
    static let claimableStatuses: Set<Spark_TransferStatus> = [
        .senderKeyTweaked,
        .receiverKeyTweaked,
        .receiverRefundSigned,
        .receiverKeyTweakApplied,
        .receiverKeyTweakLocked,
    ]

    static func run(
        fetch: (_ limit: Int, _ offset: Int) async throws -> [Spark_Transfer],
        claim: (Spark_Transfer) async throws -> Void
    ) async throws -> PendingTransferClaim {
        var claimed: [Spark_Transfer] = []
        var failures: [PendingTransferClaim.Failure] = []
        var attempted = Set<String>()
        var offset = 0
        for _ in 0..<maxBatches {
            try Task.checkCancellation()
            let batch = try await fetch(batchSize, offset)
            if batch.isEmpty {
                break
            }
            var progress = false
            for transfer in batch where claimableStatuses.contains(transfer.status) && !attempted.contains(transfer.id) {
                try Task.checkCancellation()
                attempted.insert(transfer.id)
                do {
                    try await claim(transfer)
                    claimed.append(transfer)
                    progress = true
                } catch {
                    failures.append(PendingTransferClaim.Failure(transferId: transfer.id, error: error))
                }
            }
            if batch.count < batchSize {
                break
            }
            offset = progress ? 0 : offset + batch.count
        }
        var result = PendingTransferClaim(claimedTransferIds: claimed.map(\.id), failures: failures)
        result.claimedTransfers = claimed
        return result
    }
}

extension SparkWallet {
    /// Query pending transfers where this wallet is the receiver. `limit` 0 asks for the server's
    /// largest page (100).
    func queryPendingTransfers(limit: Int = 0, offset: Int = 0) async throws -> [Spark_Transfer] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var filter = Spark_TransferFilter()
        filter.receiverIdentityPublicKey = signer.identityPublicKey
        filter.network = config.networkProto
        filter.limit = Int64(limit)
        filter.offset = Int64(offset)

        let response = try await client.query_pending_transfers(
            request: ClientRequest(message: filter, metadata: metadata)
        )
        return response.transfers
    }

    /// Claim every pending inbound transfer (Spark transfers, Lightning receives, deposits the SSP
    /// credited) and report what could not be claimed.
    ///
    /// Claims run one at a time, wallet-wide: a swap's claim of its counter-transfer or a
    /// concurrent pass waits for this one. A transfer that cannot be claimed is recorded in
    /// `failures` and the pass moves on to the rest, as the reference SDK does; a transfer the
    /// operators already recorded as claimed by this wallet counts as claimed.
    ///
    /// Claimed leaves whose refund timelock is in the renewal range (100…199 — a transfer from a
    /// leaf at 200 arrives at 100) are renewed right away, best effort, as the reference SDK does
    /// when it registers claimed leaves; spend paths renew anything that is left.
    public func claimPendingTransfers() async throws -> PendingTransferClaim {
        let result = try await claimLock.run {
            try await PendingTransferDrain.run(
                fetch: { limit, offset in try await self.queryPendingTransfers(limit: limit, offset: offset) },
                claim: { transfer in try await self.claimTransferTreatingDuplicatesAsClaimed(transfer) }
            )
        }
        await renewClaimedLeaves(result.claimedLeafIds)
        return result
    }

    /// Best-effort renewal of the renewable leaves among `leafIds`.
    func renewClaimedLeaves(_ leafIds: [String]) async {
        guard !leafIds.isEmpty else { return }
        let ids = Set(leafIds)
        guard let leaves = try? await getLeaves().filter({ ids.contains($0.id) }),
              !Self.renewalCandidates(leaves).renewable.isEmpty else { return }
        _ = try? await renewLeaves(leaves)
    }

    /// Claim every pending inbound transfer; returns how many were claimed. Transfers that cannot
    /// be claimed no longer stop the rest — use `claimPendingTransfers()` to see them.
    @discardableResult
    public func claimAllPendingTransfers() async throws -> Int {
        try await claimPendingTransfers().claimedTransferIds.count
    }

    /// Claim one transfer under the wallet-wide claim lock (used by swaps for their
    /// counter-transfer, which a concurrent claim pass may already have claimed).
    func claimTransfer(_ transfer: Spark_Transfer) async throws {
        try await claimLock.run {
            try await self.claimTransferTreatingDuplicatesAsClaimed(transfer)
        }
    }

    /// The operators answer ALREADY_EXISTS once this receiver has claimed the transfer; like the
    /// reference SDK, confirm this wallet's leg is complete and treat it as claimed.
    private func claimTransferTreatingDuplicatesAsClaimed(_ transfer: Spark_Transfer) async throws {
        do {
            try await claimTransferNow(transfer)
        } catch let error as RPCError where error.code == .alreadyExists {
            guard TransferLeafVerifier.isReceiverLegComplete(
                try await queryTransferById(transfer.id), receiverIdentityPublicKey: signer.identityPublicKey
            ) else {
                throw error
            }
        }
    }

    /// Claim a single pending transfer using the single-call claim_transfer with ClaimPackage.
    /// A multi-receiver transfer is narrowed to this wallet's own leaves, and the sender's
    /// signature on every leaf is verified first; a transfer that fails verification is refused
    /// before any secret is decrypted or any refund is signed. Callers hold `claimLock`.
    private func claimTransferNow(_ pending: Spark_Transfer) async throws {
        let transfer = try TransferLeafVerifier.scoped(pending, toReceiver: signer.identityPublicKey)
        try TransferLeafVerifier.verify(transfer: transfer, receiverIdentityPublicKey: signer.identityPublicKey)

        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let targets = try KeyTweakHelper.matchOperators(
            server: soListResponse.signingOperators, config: config.signingOperators
        )
        let soCount = UInt32(targets.count)
        let threshold = config.signingThreshold

        let transferLeaves = transfer.leaves

        // Get signing commitments (Count=3: cpfp, direct, directFromCpfp)
        var commitmentsRequest = Spark_GetSigningCommitmentsRequest()
        commitmentsRequest.count = 3
        commitmentsRequest.nodeIDCount = UInt32(transferLeaves.count)
        let commitmentsResponse = try await client.get_signing_commitments(
            request: ClientRequest(message: commitmentsRequest, metadata: metadata)
        )
        let allCommitments = commitmentsResponse.signingCommitments
        guard allCommitments.count >= 3 * transferLeaves.count else {
            throw SparkError.invalidResponse(
                "Got \(allCommitments.count) signing commitments, need \(3 * transferLeaves.count)"
            )
        }

        var cpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []
        var directRefundJobs: [Spark_UserSignedTxSigningJob] = []
        var directFromCpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []

        var perSoTweaks: [String: Spark_ClaimLeafKeyTweaks] = [:]
        for target in targets {
            perSoTweaks[target.soID] = Spark_ClaimLeafKeyTweaks()
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
                currentTimelock -= remainder
            }
            let bit30 = rawSequence & (1 << 30)
            let cpfpSequence = bit30 | (currentTimelock & 0xFFFF)
            let directSequence = bit30 | ((currentTimelock + sparkDirectTimelockOffset) & 0xFFFF)

            // Construct refund tx trio (no direct refund for zero-timelock nodes)
            let refundTrio = try Self.leafRefundTrio(
                node: node,
                receivingPubkey: newSigningPubKey,
                network: networkStr,
                sequence: cpfpSequence,
                directSequence: directSequence
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
            let sharesByTarget = try KeyTweakHelper.shares(vssShares, for: targets)
            var pubkeyBySOID: [String: Data] = [:]
            for (target, share) in sharesByTarget {
                pubkeyBySOID[target.soID] = try getPublicKeyBytes(privateKeyBytes: share.share, compressed: true)
            }

            // Build per-SO key tweak entries
            for (target, share) in sharesByTarget {
                let soID = target.soID

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
            targets: targets,
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
