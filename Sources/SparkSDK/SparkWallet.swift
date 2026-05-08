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
    private let taskManager: ClientTaskManager

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
        (self.connectionManager, self.authenticator, self.sspClient, self.taskManager) =
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
        (self.connectionManager, self.authenticator, self.sspClient, self.taskManager) =
            Self.makeComponents(config: config, signer: self.signer)
    }

    /// Export account key material for caching (64 bytes).
    public func exportAccountKey() -> Data {
        (signer as! SparkSigner).exportAccountKey()
    }

    public init(config: SparkConfig = SparkConfig(), signer: SparkSignerProtocol) {
        self.config = config
        self.signer = signer
        (self.connectionManager, self.authenticator, self.sspClient, self.taskManager) =
            Self.makeComponents(config: config, signer: signer)
    }

    private static func makeComponents(
        config: SparkConfig,
        signer: SparkSignerProtocol
    ) -> (GrpcConnectionManager, SparkAuthenticator, SspGraphQLClient, ClientTaskManager) {
        let connectionManager = GrpcConnectionManager(addresses: config.signingOperatorAddresses)
        let authenticator = SparkAuthenticator()
        let sspAuthenticator = SspAuthenticator()
        let session = URLSession.shared
        let sspURL = config.sspURL
        let sspClient = SspGraphQLClient(
            session: session,
            sspURL: sspURL,
            getToken: { [sspAuthenticator] in
                try await sspAuthenticator.getToken(session: session, sspURL: sspURL, signer: signer)
            }
        )
        return (connectionManager, authenticator, sspClient, ClientTaskManager())
    }

    public func start() async {
        for address in config.signingOperatorAddresses {
            let mgr = connectionManager
            let task = Task {
                do {
                    let client = try await mgr.getClient(for: address)
                    try await client.runConnections()
                } catch {
                    // Client shut down or failed to connect
                }
            }
            await taskManager.add(task)
        }
    }

    public func close() async {
        await connectionManager.close()
        await taskManager.cancelAll()
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

/// Thread-safe task manager to replace mutable array on SparkWallet.
private actor ClientTaskManager {
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        tasks.append(task)
    }

    func cancelAll() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }
}
