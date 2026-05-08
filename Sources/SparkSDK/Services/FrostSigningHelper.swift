import Foundation
import SwiftProtobuf

enum FrostSigningHelper {
    static func buildSigningJob(
        leafID: String,
        signingKey: Data,
        verifyingKey: Data,
        rawTx: Data,
        sighash: Data,
        soCommitments: [String: Common_SigningCommitment]
    ) throws -> Spark_UserSignedTxSigningJob {
        let publicKey = try getPublicKeyBytes(privateKeyBytes: signingKey, compressed: true)
        let keyPackage = KeyPackage(
            secretKey: signingKey,
            publicKey: publicKey,
            verifyingKey: verifyingKey
        )

        let nonceResult = try frostNonce(keyPackage: keyPackage)

        // Convert proto commitments to native type
        var nativeCommitments: [String: SigningCommitment] = [:]
        for (soID, protoCommitment) in soCommitments {
            nativeCommitments[soID] = SigningCommitment(
                hiding: protoCommitment.hiding,
                binding: protoCommitment.binding
            )
        }

        let userSignature = try signFrost(
            msg: sighash,
            keyPackage: keyPackage,
            nonce: nonceResult.nonce,
            selfCommitment: nonceResult.commitment,
            statechainCommitments: nativeCommitments,
            adaptorPublicKey: nil
        )

        var signingCommitments = Spark_SigningCommitments()
        for (soID, commitment) in soCommitments {
            signingCommitments.signingCommitments[soID] = commitment
        }

        var job = Spark_UserSignedTxSigningJob()
        job.leafID = leafID
        job.signingPublicKey = publicKey
        job.rawTx = rawTx
        job.signingNonceCommitment = Common_SigningCommitment.with {
            $0.hiding = nonceResult.commitment.hiding
            $0.binding = nonceResult.commitment.binding
        }
        job.userSignature = userSignature
        job.signingCommitments = signingCommitments
        return job
    }

    static func buildUnsignedJob(
        signingPublicKey: Data,
        rawTx: Data,
        hidingNonce: Data,
        bindingNonce: Data
    ) -> Spark_SigningJob {
        var job = Spark_SigningJob()
        job.signingPublicKey = signingPublicKey
        job.rawTx = rawTx
        job.signingNonceCommitment = Common_SigningCommitment.with {
            $0.hiding = hidingNonce
            $0.binding = bindingNonce
        }
        return job
    }
}
