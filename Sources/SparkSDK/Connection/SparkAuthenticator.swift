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
    /// The authentication in progress per operator and identity: concurrent callers share it
    /// instead of each running a challenge (the reference SDK's `authInflight`).
    private var inFlight: [String: Task<CachedToken, any Swift.Error>] = [:]
    private static let refreshBuffer: TimeInterval = 60
    /// Challenge exchanges tried before authentication fails, as in the reference SDK.
    static let maxAttempts = 8
    /// Token expiry is the operators' time, so it is compared with their clock, not the device's.
    private let clock: ServerClock

    init(clock: ServerClock = ServerClock()) {
        self.clock = clock
    }

    func getToken(
        connectionManager: GrpcConnectionManager,
        soAddress: String,
        signer: SparkSignerProtocol
    ) async throws -> String {
        let cacheKey = "\(soAddress):\(signer.identityPublicKey.hexString)"

        if let cached = tokenCache[cacheKey],
           cached.expiresAt > clock.now().addingTimeInterval(Self.refreshBuffer) {
            return cached.token
        }
        if let pending = inFlight[cacheKey] {
            return try await pending.value.token
        }

        let authentication = Task {
            try await self.authenticate(connectionManager: connectionManager, soAddress: soAddress, signer: signer)
        }
        inFlight[cacheKey] = authentication
        defer { inFlight[cacheKey] = nil }
        let token = try await authentication.value
        tokenCache[cacheKey] = token
        return token.token
    }

    /// Forget this operator's cached session if it is still `token`. Called by
    /// `AuthRetryInterceptor` when the operator answers UNAUTHENTICATED: a token the server no
    /// longer honours stays "valid" by its own `expiresAt`, and reusing it would fail every call
    /// until then. Only the rejected token is dropped — a concurrent call may already have
    /// replaced it with a fresh one. Per operator and identity, like the official SDK's cache.
    func invalidate(soAddress: String, signer: SparkSignerProtocol, token: String) {
        let cacheKey = "\(soAddress):\(signer.identityPublicKey.hexString)"
        if tokenCache[cacheKey]?.token == token {
            tokenCache[cacheKey] = nil
        }
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

    /// Up to `maxAttempts` challenge exchanges, as the reference SDK makes them: a fresh challenge
    /// at once when the last one expired or was already used (a lost answer), after 250 ms when
    /// the connection failed; any other failure ends authentication.
    private func authenticate(
        connectionManager: GrpcConnectionManager,
        soAddress: String,
        signer: SparkSignerProtocol
    ) async throws -> CachedToken {
        var lastError: (any Swift.Error)?
        for _ in 0..<Self.maxAttempts {
            do {
                return try await exchangeChallenge(connectionManager: connectionManager, soAddress: soAddress, signer: signer)
            } catch let error as RPCError where Self.isStaleChallenge(error) {
                lastError = error
            } catch let error as RPCError where Self.isConnectionFailure(error) {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError ?? SparkError.authenticationFailed("authentication failed after \(Self.maxAttempts) attempts")
    }

    /// The operator refused the challenge as expired or already used; a fresh one will do.
    static func isStaleChallenge(_ error: RPCError) -> Bool {
        error.code == .failedPrecondition
            && (error.message.contains("challenge expired") || error.message.contains("challenge reused"))
    }

    /// The exchange failed on the way rather than on its content.
    static func isConnectionFailure(_ error: RPCError) -> Bool {
        [.unavailable, .internalError, .unknown, .cancelled, .deadlineExceeded].contains(error.code)
    }

    private func exchangeChallenge(
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
