import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

actor GrpcConnectionManager {
    private var clients: [String: GRPCClient<HTTP2ClientTransport.Posix>] = [:]
    private let addresses: [String]
    /// Builds the interceptors for one operator's client — see `AuthRetryInterceptor`.
    private let interceptorFactory: @Sendable (String) -> [any ClientInterceptor]

    /// Deadline applied to every RPC by default (`serviceConfig`). Mirrors the official Spark
    /// SDK's last-resort 60 s cap on unary calls: without any deadline, grpc-swift queues an RPC
    /// on a not-yet-ready client indefinitely, so a connection that looks alive but never
    /// answers parks the caller until the process restarts.
    static let defaultRPCTimeout: Duration = .seconds(60)

    /// The official SDK's retry policy, verbatim: up to 3 attempts, 1 s → 10 s exponential
    /// backoff, on UNAVAILABLE and CANCELLED only. That is how a pooled connection the server
    /// closed while idle (or rotated out by its max connection age) heals: the failed attempt
    /// never reached the server, and the retry re-establishes the connection. A deadline is
    /// deliberately NOT retryable.
    static let retryPolicy = RetryPolicy(
        maxAttempts: 3,
        initialBackoff: .seconds(1),
        maxBackoff: .seconds(10),
        backoffMultiplier: 2,
        retryableStatusCodes: [.unavailable, .cancelled]
    )

    /// The event subscription is a long-lived server stream: unbounded and never retried here
    /// (reconnecting it with backoff is the subscriber's job, as in the official wallet). A
    /// per-method entry takes precedence over the global (empty-name) one.
    static let serviceConfig = ServiceConfig(methodConfig: [
        MethodConfig(names: [MethodConfig.Name(service: "", method: "")],
                     timeout: defaultRPCTimeout,
                     executionPolicy: .retry(retryPolicy)),
        MethodConfig(names: [MethodConfig.Name(service: "spark.SparkService", method: "subscribe_to_events")],
                     timeout: nil,
                     executionPolicy: nil),
    ])

    init(addresses: [String],
         interceptorFactory: @escaping @Sendable (String) -> [any ClientInterceptor] = { _ in [] }) {
        self.addresses = addresses
        self.interceptorFactory = interceptorFactory
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

        // Transport on the defaults, like the official SDK: no client keepalive (the operators
        // send their own keepalive pings and bound how often clients may ping), default idle time.
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: useTLS ? .tls(.defaults) : .plaintext,
            serviceConfig: Self.serviceConfig
        )

        let client = GRPCClient(transport: transport, interceptors: interceptorFactory(address))
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
