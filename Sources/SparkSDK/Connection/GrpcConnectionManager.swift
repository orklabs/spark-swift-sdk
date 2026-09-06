import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

actor GrpcConnectionManager {
    private var clients: [String: GRPCClient<HTTP2ClientTransport.Posix>] = [:]
    private let addresses: [String]
    /// Applied to every client — see `AuthInvalidatingInterceptor`.
    private let interceptors: [any ClientInterceptor]

    /// Deadline applied to every RPC by default (`serviceConfig`). Generous enough for the
    /// multi-MB `query_nodes` behind a recovery snapshot on a slow link; bounded so a connection
    /// that looks alive but never answers (a socket iOS dropped in the background, a NAT that
    /// forgot the flow) fails the call instead of parking the caller until the process restarts.
    /// Without any deadline, grpc-swift queues an RPC on a not-yet-ready client indefinitely.
    static let defaultRPCTimeout: Duration = .seconds(60)

    /// The event subscription is a long-lived server stream and must stay unbounded; a
    /// per-method entry takes precedence over the global (empty-name) one.
    static let serviceConfig = ServiceConfig(methodConfig: [
        MethodConfig(names: [MethodConfig.Name(service: "", method: "")], timeout: defaultRPCTimeout),
        MethodConfig(names: [MethodConfig.Name(service: "spark.SparkService", method: "subscribe_to_events")],
                     timeout: nil),
    ])

    /// Connection hygiene. Idle connections are dropped after 5 minutes (the default is 30) so a
    /// call after a long pause opens a fresh socket rather than probing a stale one. Keepalive
    /// pings run only while a call is in flight and no more often than every 5 minutes — under
    /// the ping policy gRPC servers enforce by default (more frequent pings, or pings without
    /// calls, earn a `too_many_pings` GOAWAY that would make reconnects worse, not better) —
    /// so a dead connection under a long stream is still noticed, not just at the TCP timeout.
    static var transportConfig: HTTP2ClientTransport.Posix.Config {
        var config = HTTP2ClientTransport.Posix.Config.defaults
        config.connection = .init(
            maxIdleTime: .seconds(300),
            keepalive: .init(time: .seconds(300), timeout: .seconds(20), allowWithoutCalls: false)
        )
        return config
    }

    init(addresses: [String], interceptors: [any ClientInterceptor] = []) {
        self.addresses = addresses
        self.interceptors = interceptors
    }

    func getClient(for address: String) throws -> GRPCClient<HTTP2ClientTransport.Posix> {
        if let existing = clients[address] {
            return existing
        }

        guard let url = URL(string: address),
              let host = url.host else {
            throw SparkError.grpcError("Invalid SO address: \(address)")
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let useTLS = url.scheme == "https"

        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: useTLS ? .tls(.defaults) : .plaintext,
            config: Self.transportConfig,
            serviceConfig: Self.serviceConfig
        )

        let client = GRPCClient(transport: transport, interceptors: interceptors)
        clients[address] = client

        // Drive the client's connection loop. When it returns the client is terminal (shut down,
        // or the transport failed outright): evict it so the next call builds a fresh one instead
        // of throwing "client is stopped" for this operator until the wallet is closed.
        Task { [weak self] in
            try? await client.runConnections()
            await self?.evict(client, for: address)
        }

        return client
    }

    private func evict(_ client: GRPCClient<HTTP2ClientTransport.Posix>, for address: String) {
        if clients[address] === client {
            clients[address] = nil
        }
    }

    func getSparkClient(for address: String) throws -> Spark_SparkService.Client<HTTP2ClientTransport.Posix> {
        let client = try getClient(for: address)
        return Spark_SparkService.Client(wrapping: client)
    }

    func getAuthnClient(for address: String) throws -> SparkAuthn_SparkAuthnService.Client<HTTP2ClientTransport.Posix> {
        let client = try getClient(for: address)
        return SparkAuthn_SparkAuthnService.Client(wrapping: client)
    }

    func getSparkTokenClient(for address: String) throws -> SparkToken_SparkTokenService.Client<HTTP2ClientTransport.Posix> {
        let client = try getClient(for: address)
        return SparkToken_SparkTokenService.Client(wrapping: client)
    }

    var allAddresses: [String] { addresses }

    func close() {
        for (_, client) in clients {
            client.beginGracefulShutdown()
        }
        clients.removeAll()
    }
}
