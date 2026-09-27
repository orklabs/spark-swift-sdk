import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

public final class SparkWallet: Sendable {
    let config: SparkConfig
    let signer: SparkSignerProtocol
    let connectionManager: GrpcConnectionManager
    let authenticator: SparkAuthenticator
    let sspClient: SspGraphQLClient
    /// Serialises transfer claims (see `claimPendingTransfers`).
    let claimLock = AsyncSerialLock()
    /// Running event streams, stopped by `close()`.
    let eventStreams = EventStreamRegistry()
    /// The operators' clock, estimated from their answers (see `ServerClock`).
    let serverClock: ServerClock
    /// Token outputs picked by sends that may still be in flight (see `TokenOutputLocks`).
    let tokenOutputLocks = TokenOutputLocks()

    public var identityPublicKeyHex: String {
        signer.identityPublicKey.hexString
    }

    /// Sign a message hash with the identity key. Returns DER-encoded signature.
    public func signWithIdentityKey(_ messageHash: Data) throws -> Data {
        try signer.signWithIdentityKey(messageHash)
    }

    /// - Parameters:
    ///   - account: BIP32 account index. Defaults to `1` on mainnet, `0` on regtest
    ///     (matching the TypeScript Spark SDK behaviour).
    ///   - validateMnemonic: Reject phrases that fail BIP-39 wordlist or checksum validation
    ///     with `SparkError.invalidMnemonic` instead of silently deriving a different wallet.
    ///     Defaults to `true`; pass `false` only for phrases known to be non-standard.
    public init(config: SparkConfig = SparkConfig(), mnemonic: String, account: Int? = nil, validateMnemonic: Bool = true) throws {
        self.config = config
        self.serverClock = ServerClock()
        let resolvedAccount = account ?? (config.network == .mainnet ? 1 : 0)
        self.signer = try SparkSigner(mnemonic: mnemonic, account: resolvedAccount, validateMnemonic: validateMnemonic)
        (self.connectionManager, self.authenticator, self.sspClient) =
            Self.makeComponents(config: config, signer: self.signer, serverClock: self.serverClock)
    }

    /// Initialize from pre-derived account key material (64 bytes: key + chain code).
    public init(config: SparkConfig = SparkConfig(), accountKey: Data) throws {
        self.serverClock = ServerClock()
        guard accountKey.count == 64 else {
            throw SparkError.keyDerivationFailed
        }
        let key = accountKey.prefix(32)
        let chainCode = accountKey.suffix(32)
        self.config = config
        self.signer = try SparkSigner(accountKey: Data(key), accountChainCode: Data(chainCode))
        (self.connectionManager, self.authenticator, self.sspClient) =
            Self.makeComponents(config: config, signer: self.signer, serverClock: self.serverClock)
    }

    /// Export account key material for caching (64 bytes). Only available when the wallet was
    /// created from a mnemonic or an account key; a custom signer keeps its own material.
    public func exportAccountKey() throws -> Data {
        guard let signer = signer as? SparkSigner else {
            throw SparkError.invalidArgument("exportAccountKey is only available for wallets created from a mnemonic or account key")
        }
        return signer.exportAccountKey()
    }

    public init(config: SparkConfig = SparkConfig(), signer: SparkSignerProtocol) {
        self.serverClock = ServerClock()
        self.config = config
        self.signer = signer
        (self.connectionManager, self.authenticator, self.sspClient) =
            Self.makeComponents(config: config, signer: signer, serverClock: self.serverClock)
    }

    private static func makeComponents(
        config: SparkConfig,
        signer: SparkSignerProtocol,
        serverClock: ServerClock
    ) -> (GrpcConnectionManager, SparkAuthenticator, SspGraphQLClient) {
        let authenticator = SparkAuthenticator(clock: serverClock)
        // Every operator client sends each attempt with the operator's current token and drops a
        // token the operator rejects (the official SDK's auth middleware); the transport's retry
        // policy then re-issues the call with a fresh one. The manager is captured weakly: the
        // interceptor lives inside the clients the manager owns.
        let managerRef = WeakConnectionManager()
        let connectionManager = GrpcConnectionManager(
            addresses: config.signingOperatorAddresses,
            // Operator traffic carries session tokens and signing material: TLS on mainnet.
            allowsPlaintext: config.network != .mainnet,
            interceptorFactory: { address in
                let auth = AuthRetryInterceptor(
                    currentToken: {
                        guard let manager = managerRef.manager else {
                            throw SparkError.grpcError("Connection manager released")
                        }
                        return try await authenticator.getToken(
                            connectionManager: manager, soAddress: address, signer: signer
                        )
                    },
                    invalidate: { token in
                        await authenticator.invalidate(soAddress: address, signer: signer, token: token)
                    }
                )
                // Innermost, the clock measures only the operator's round trip.
                return [auth, ServerTimeInterceptor(clock: serverClock)]
            }
        )
        managerRef.manager = connectionManager
        let sspAuthenticator = SspAuthenticator()
        let session = URLSession.shared
        let sspURL = config.sspURL
        let sspClient = SspGraphQLClient(
            session: session,
            sspURL: sspURL,
            getToken: { [sspAuthenticator] in
                try await sspAuthenticator.getToken(session: session, sspURL: sspURL, signer: signer)
            },
            invalidateToken: { [sspAuthenticator] in
                await sspAuthenticator.invalidate()
            }
        )
        return (connectionManager, authenticator, sspClient)
    }

    /// Warm every operator's connection. `getClient` drives each client's connection loop itself
    /// (and evicts the client when that loop ends), so a second `runConnections()` here would only
    /// throw "already running"; callers that never `start()` get lazily-built clients on first use.
    public func start() async {
        for address in config.signingOperatorAddresses {
            _ = try? await connectionManager.getClient(for: address)
        }
    }

    /// Shut every operator connection down. The wallet stays usable: the next call after `close()`
    /// builds fresh clients (that is how a host app cycles connections around backgrounding).
    /// Stops the wallet's event streams and shuts its operator connections down.
    public func close() async {
        await eventStreams.close()
        await connectionManager.close()
    }

    func getAuthMetadata(for soAddress: String) async throws -> Metadata {
        try await authenticator.getAuthMetadata(
            connectionManager: connectionManager,
            soAddress: soAddress,
            signer: signer
        )
    }

    func getCoordinatorClient() async throws -> Spark_SparkService.Client<HTTP2ClientTransport.Posix> {
        try await connectionManager.getSparkClient(for: config.coordinatorAddress)
    }

    func getTokenClient() async throws -> SparkToken_SparkTokenService.Client<HTTP2ClientTransport.Posix> {
        try await connectionManager.getSparkTokenClient(for: config.coordinatorAddress)
    }

    func makeAuthenticatedRequest<M: Sendable>(message: M) async throws -> ClientRequest<M> {
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        return ClientRequest(message: message, metadata: metadata)
    }
}

/// Lets the auth interceptors reach the connection manager that owns their clients without a
/// retain cycle.
private final class WeakConnectionManager: @unchecked Sendable {
    weak var manager: GrpcConnectionManager?
}
