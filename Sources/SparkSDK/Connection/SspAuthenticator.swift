import Foundation
import CryptoKit

actor SspAuthenticator {
    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    private var tokenCache: [String: CachedToken] = [:]
    private static let refreshBuffer: TimeInterval = 60

    func getToken(
        session: URLSession,
        sspURL: String,
        signer: SparkSignerProtocol
    ) async throws -> String {
        let cacheKey = "ssp:\(signer.identityPublicKey.hexString)"

        if let cached = tokenCache[cacheKey],
           cached.expiresAt > Date().addingTimeInterval(Self.refreshBuffer) {
            return cached.token
        }

        let token = try await authenticate(session: session, sspURL: sspURL, signer: signer)
        tokenCache[cacheKey] = token
        return token.token
    }

    /// Forget the cached session. `SspGraphQLClient` calls this when the SSP rejects the token
    /// before its `valid_until` (rotation, restart): the next `getToken` authenticates afresh
    /// instead of replaying the rejected one until the process restarts.
    func invalidate() {
        tokenCache.removeAll()
    }

    private func authenticate(
        session: URLSession,
        sspURL: String,
        signer: SparkSignerProtocol
    ) async throws -> CachedToken {
        let identityPubKeyHex = signer.identityPublicKey.hexString

        // Step 1: Get challenge
        let challengeResult = try await executeGraphQL(
            session: session,
            url: sspURL,
            token: nil,
            query: GraphQLMutations.getChallenge,
            variables: ["public_key": identityPubKeyHex]
        )

        guard let getChallenge = challengeResult["get_challenge"] as? [String: Any],
              let protectedChallenge = getChallenge["protected_challenge"] as? String else {
            throw SparkError.authenticationFailed("Invalid challenge response")
        }

        // Step 2: Sign the challenge (base64url encoded)
        guard let challengeBytes = decodeBase64URL(protectedChallenge) else {
            throw SparkError.authenticationFailed("Invalid base64url challenge")
        }
        let challengeHash = Data(SHA256.hash(data: challengeBytes))
        let signature = try signer.signWithIdentityKey(challengeHash)
        let signatureBase64 = signature.base64EncodedString()

        // Step 3: Verify and get token
        let verifyResult = try await executeGraphQL(
            session: session,
            url: sspURL,
            token: nil,
            query: GraphQLMutations.verifyChallenge,
            variables: [
                "protected_challenge": protectedChallenge,
                "signature": signatureBase64,
                "identity_public_key": identityPubKeyHex,
            ]
        )

        guard let verifyChallenge = verifyResult["verify_challenge"] as? [String: Any],
              let sessionToken = verifyChallenge["session_token"] as? String,
              let validUntil = verifyChallenge["valid_until"] as? String else {
            throw SparkError.authenticationFailed("Invalid verify response")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.date(from: validUntil) ?? Date().addingTimeInterval(3600)

        return CachedToken(token: sessionToken, expiresAt: expiresAt)
    }
}
