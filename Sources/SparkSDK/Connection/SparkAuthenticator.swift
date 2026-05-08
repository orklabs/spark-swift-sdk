import Foundation
import CryptoKit
import GRPCCore
import GRPCProtobuf
import SwiftProtobuf

actor SparkAuthenticator {
    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    private var tokenCache: [String: CachedToken] = [:]
    private static let refreshBuffer: TimeInterval = 60

    func getToken(
        connectionManager: GrpcConnectionManager,
        soAddress: String,
        signer: SparkSignerProtocol
    ) async throws -> String {
        let cacheKey = "\(soAddress):\(signer.identityPublicKey.hexString)"

        if let cached = tokenCache[cacheKey],
           cached.expiresAt > Date().addingTimeInterval(Self.refreshBuffer) {
            return cached.token
        }

        let token = try await authenticate(
            connectionManager: connectionManager,
            soAddress: soAddress,
            signer: signer
        )
        tokenCache[cacheKey] = token
        return token.token
    }

    func getAuthMetadata(
        connectionManager: GrpcConnectionManager,
        soAddress: String,
        signer: SparkSignerProtocol
    ) async throws -> Metadata {
        let token = try await getToken(connectionManager: connectionManager, soAddress: soAddress, signer: signer)
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        return metadata
    }

    private func authenticate(
        connectionManager: GrpcConnectionManager,
        soAddress: String,
        signer: SparkSignerProtocol
    ) async throws -> CachedToken {
        let authnClient = try await connectionManager.getAuthnClient(for: soAddress)

        // Step 1: Get challenge
        var challengeRequest = SparkAuthn_GetChallengeRequest()
        challengeRequest.publicKey = signer.identityPublicKey

        let challengeResponse = try await authnClient.get_challenge(
            request: ClientRequest(message: challengeRequest)
        )

        // Step 2: Sign the challenge
        let challengeData = try challengeResponse.protectedChallenge.challenge.serializedData()
        let challengeHash = Data(CryptoKit.SHA256.hash(data: challengeData))
        let signature = try signer.signWithIdentityKey(challengeHash)

        // Step 3: Verify and get token
        var verifyRequest = SparkAuthn_VerifyChallengeRequest()
        verifyRequest.protectedChallenge = challengeResponse.protectedChallenge
        verifyRequest.signature = signature
        verifyRequest.publicKey = signer.identityPublicKey

        let verifyResponse = try await authnClient.verify_challenge(
            request: ClientRequest(message: verifyRequest)
        )

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(verifyResponse.expirationTimestamp))
        return CachedToken(token: verifyResponse.sessionToken, expiresAt: expiresAt)
    }
}
