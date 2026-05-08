import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

actor GrpcConnectionManager {
    private var clients: [String: GRPCClient<HTTP2ClientTransport.Posix>] = [:]
    private let addresses: [String]

    init(addresses: [String]) {
        self.addresses = addresses
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

        let transport: HTTP2ClientTransport.Posix
        if useTLS {
            transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: .tls(.defaults)
            )
        } else {
            transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: .plaintext
            )
        }

        let client = GRPCClient(transport: transport)
        clients[address] = client

        // Start connection run loop for dynamically created clients
        Task {
            try? await client.runConnections()
        }

        return client
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
