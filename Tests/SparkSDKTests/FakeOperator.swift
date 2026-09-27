import Foundation
import Testing
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
@testable import SparkSDK

/// A signing-operator stand-in on a local HTTP/2 port, for exercising the SDK's real transport
/// stack (connection manager, interceptors, authenticator) without mainnet.
///
/// It issues session tokens through the real authn RPCs (`session-1`, `session-2`, …) and answers
/// SparkService calls. Tokens the `rejects` predicate names are refused with UNAUTHENTICATED the
/// way an operator does: before any response headers (its auth interceptor), or after them when an
/// earlier operator interceptor already set a header such as `x-trace-id`.
actor FakeOperatorState {
    enum Rejection: Sendable {
        case beforeHeaders
        case afterHeaders
    }

    let rejection: Rejection
    /// What `generate_deposit_address` and `generate_static_deposit_address` hand out.
    let depositAddress: Spark_Address
    private let rejects: @Sendable (_ token: String) -> Bool
    /// Session tokens handed out by `verify_challenge`, in order.
    private(set) var issuedTokens: [String] = []
    /// `"<method> <authorization header>"` for every SparkService call received.
    private(set) var calls: [String] = []

    init(
        rejection: Rejection = .beforeHeaders,
        depositAddress: Spark_Address = Spark_Address(),
        rejects: @escaping @Sendable (_ token: String) -> Bool
    ) {
        self.rejection = rejection
        self.depositAddress = depositAddress
        self.rejects = rejects
    }

    func issueToken() -> String {
        let token = "session-\(issuedTokens.count + 1)"
        issuedTokens.append(token)
        return token
    }

    /// Records the call; returns whether its token is accepted.
    func admit(_ method: String, authorization: String) -> Bool {
        calls.append("\(method) \(authorization)")
        let token = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : authorization
        return !token.isEmpty && !rejects(token)
    }
}

struct FakeOperator: RegistrableRPCService {
    let state: FakeOperatorState

    static let unauthenticated = RPCError(code: .unauthenticated, message: "failed to verify token: token has expired")

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: SparkAuthn_SparkAuthnService.Method.get_challenge.descriptor,
            deserializer: ProtobufDeserializer<SparkAuthn_GetChallengeRequest>(),
            serializer: ProtobufSerializer<SparkAuthn_GetChallengeResponse>()
        ) { _, _ in
            var response = SparkAuthn_GetChallengeResponse()
            response.protectedChallenge.challenge.nonce = Data(repeating: 7, count: 32)
            response.protectedChallenge.challenge.timestamp = Int64(Date().timeIntervalSince1970)
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: SparkAuthn_SparkAuthnService.Method.verify_challenge.descriptor,
            deserializer: ProtobufDeserializer<SparkAuthn_VerifyChallengeRequest>(),
            serializer: ProtobufSerializer<SparkAuthn_VerifyChallengeResponse>()
        ) { [state] _, _ in
            var response = SparkAuthn_VerifyChallengeResponse()
            response.sessionToken = await state.issueToken()
            response.expirationTimestamp = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.query_nodes.descriptor,
            deserializer: ProtobufDeserializer<Spark_QueryNodesRequest>(),
            serializer: ProtobufSerializer<Spark_QueryNodesResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_nodes", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            return StreamingServerResponse(single: ServerResponse(message: Spark_QueryNodesResponse()))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.generate_deposit_address.descriptor,
            deserializer: ProtobufDeserializer<Spark_GenerateDepositAddressRequest>(),
            serializer: ProtobufSerializer<Spark_GenerateDepositAddressResponse>()
        ) { [state] request, _ in
            guard await state.admit("generate_deposit_address", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            var response = Spark_GenerateDepositAddressResponse()
            response.depositAddress = state.depositAddress
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.generate_static_deposit_address.descriptor,
            deserializer: ProtobufDeserializer<Spark_GenerateStaticDepositAddressRequest>(),
            serializer: ProtobufSerializer<Spark_GenerateStaticDepositAddressResponse>()
        ) { [state] request, _ in
            guard await state.admit("generate_static_deposit_address", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            var response = Spark_GenerateStaticDepositAddressResponse()
            response.depositAddress = state.depositAddress
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.subscribe_to_events.descriptor,
            deserializer: ProtobufDeserializer<Spark_SubscribeToEventsRequest>(),
            serializer: ProtobufSerializer<Spark_SubscribeToEventsResponse>()
        ) { [state] request, _ in
            guard await state.admit("subscribe_to_events", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            return StreamingServerResponse { writer in
                var event = Spark_SubscribeToEventsResponse()
                event.connected = Spark_ConnectedEvent()
                try await writer.write(event)
                return [:]
            }
        }
    }

    static func authorization(_ metadata: Metadata) -> String {
        metadata[stringValues: "authorization"].first { _ in true } ?? ""
    }

    static func reject<Output>(_ state: FakeOperatorState) async -> StreamingServerResponse<Output> {
        switch state.rejection {
        case .beforeHeaders:
            return StreamingServerResponse(error: unauthenticated)
        case .afterHeaders:
            return StreamingServerResponse(metadata: ["x-trace-id": "0af7651916cd43dd8448eb211c80319c"]) { _ in
                throw unauthenticated
            }
        }
    }
}

/// Runs `body` against a regtest wallet whose only operator is a `FakeOperator` on a local port.
@discardableResult
func withFakeOperator<T: Sendable>(
    _ state: FakeOperatorState,
    _ body: (SparkWallet) async throws -> T
) async throws -> T {
    let transport = HTTP2ServerTransport.Posix(
        address: .ipv4(host: "127.0.0.1", port: 0),
        transportSecurity: .plaintext
    )
    return try await withGRPCServer(transport: transport, services: [FakeOperator(state: state)]) { _ in
        let port = try #require(try await transport.listeningAddress.ipv4?.port)
        let config = SparkConfig(
            network: .regtest,
            signingOperators: [SigningOperatorConfig(
                address: "http://127.0.0.1:\(port)",
                identifier: "0000000000000000000000000000000000000000000000000000000000000001",
                identityPublicKeyHex: "03dfbdff4b6332c220f8fa2ba8ed496c698ceada563fa01b67d9983bfc5c95e763"
            )]
        )
        let wallet = try SparkWallet(
            config: config,
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            account: 0
        )
        do {
            let result = try await body(wallet)
            await wallet.close()
            return result
        } catch {
            await wallet.close()
            throw error
        }
    }
}
