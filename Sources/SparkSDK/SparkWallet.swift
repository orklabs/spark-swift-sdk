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

    public var identityPublicKeyHex: String {
        signer.identityPublicKey.hexString
    }

    /// Sign a message hash with the identity key. Returns DER-encoded signature.
    public func signWithIdentityKey(_ messageHash: Data) throws -> Data {
        try signer.signWithIdentityKey(messageHash)
    }

    /// - Parameter account: BIP32 account index. Defaults to `1` on mainnet, `0` on regtest
    ///   (matching the TypeScript Spark SDK behaviour).
    public init(config: SparkConfig = SparkConfig(), mnemonic: String, account: Int? = nil) throws {
        self.config = config
        let resolvedAccount = account ?? (config.network == .mainnet ? 1 : 0)
        self.signer = try SparkSigner(mnemonic: mnemonic, account: resolvedAccount)
        (self.connectionManager, self.authenticator, self.sspClient) =
            Self.makeComponents(config: config, signer: self.signer)
    }

    /// Initialize from pre-derived account key material (64 bytes: key + chain code).
    public init(config: SparkConfig = SparkConfig(), accountKey: Data) throws {
        guard accountKey.count == 64 else {
            throw SparkError.keyDerivationFailed
        }
        let key = accountKey.prefix(32)
        let chainCode = accountKey.suffix(32)
        self.config = config
        self.signer = try SparkSigner(accountKey: Data(key), accountChainCode: Data(chainCode))
        (self.connectionManager, self.authenticator, self.sspClient) =
            Self.makeComponents(config: config, signer: self.signer)
    }

    /// Export account key material for caching (64 bytes).
    public func exportAccountKey() -> Data {
        (signer as! SparkSigner).exportAccountKey()
    }

    public init(config: SparkConfig = SparkConfig(), signer: SparkSignerProtocol) {
        self.config = config
        self.signer = signer
        (self.connectionManager, self.authenticator, self.sspClient) =
            Self.makeComponents(config: config, signer: signer)
    }

    private static func makeComponents(
        config: SparkConfig,
        signer: SparkSignerProtocol
    ) -> (GrpcConnectionManager, SparkAuthenticator, SspGraphQLClient) {
        let authenticator = SparkAuthenticator()
        // Every operator client drops the cached session tokens on UNAUTHENTICATED, so a token
        // the server stopped honouring is replaced on the next call rather than replayed until
        // the process restarts.
        let connectionManager = GrpcConnectionManager(
            addresses: config.signingOperatorAddresses,
            interceptors: [AuthInvalidatingInterceptor(authenticator: authenticator)]
        )
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
    public func close() async {
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
