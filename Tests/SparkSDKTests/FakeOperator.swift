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

    /// How the event subscription behaves after its `connected` event.
    enum Subscription: Sendable {
        /// The stream ends.
        case end
        /// One heartbeat, then 3 s of silence (the local server waits for it before stopping).
        case heartbeatThenSilence
        /// 3 s of silence, without heartbeats.
        case silence
    }

    let rejection: Rejection
    private(set) var subscription: Subscription = .end
    /// How far the operator's clock is from the device's; its answers carry its `date`.
    private(set) var clockOffset: TimeInterval = 0
    /// What `generate_deposit_address` and `generate_static_deposit_address` hand out.
    let depositAddress: Spark_Address
    private let rejects: @Sendable (_ token: String) -> Bool
    /// Session tokens handed out by `verify_challenge`, in order.
    private(set) var issuedTokens: [String] = []
    /// Challenges handed out by `get_challenge`.
    private(set) var challengesIssued = 0
    /// Errors the next `verify_challenge` calls fail with, in order.
    private var verifyFailures: [RPCError] = []
    /// How long `verify_challenge` takes.
    private(set) var verifyDelay: Duration = .zero
    /// `"<method> <authorization header>"` for every SparkService call received.
    private(set) var calls: [String] = []
    /// Lightning sends `query_htlc` reports as held, matched by transfer id.
    private(set) var heldSends: [Spark_PreimageRequestWithTransfer] = []
    /// Transfers `query_transfers_by_id` knows, matched by id.
    private(set) var knownTransfers: [Spark_Transfer] = []
    /// Token outputs `query_token_outputs` returns, in one page.
    private(set) var tokenOutputs: [SparkToken_OutputWithPreviousTransactionData] = []
    /// Token identifiers per `query_token_metadata` call; more than 500 are refused, as the
    /// operators refuse them.
    private(set) var metadataRequestSizes: [Int] = []
    /// Whether `query_token_metadata` fails.
    private(set) var failsTokenMetadata = false
    /// The outputs (`TokenOutputLocks.key`) each `start_transaction` spends, in order. Every
    /// start fails, so nothing is spent.
    private(set) var startedSpends: [[String]] = []
    /// The partial transaction and `x-idempotency-key` of each `start_transaction`, in order.
    private(set) var startedTransactions: [(transaction: SparkToken_TokenTransaction, idempotencyKey: String?)] = []
    /// Nodes `query_nodes` pages through by id, as the operators page an owner query.
    private(set) var nodes: [Spark_TreeNode] = []
    /// `(limit, offset)` of every `query_nodes` call.
    private(set) var nodePages: [[Int64]] = []
    /// What every `initiate_preimage_swap_v3` fails with.
    private(set) var preimageSwapError = RPCError(code: .internalError, message: "preimage swap failed")
    /// The `x-idempotency-key` of every `initiate_preimage_swap_v3`, in order.
    private(set) var preimageSwapIdempotencyKeys: [String] = []

    init(
        rejection: Rejection = .beforeHeaders,
        depositAddress: Spark_Address = Spark_Address(),
        rejects: @escaping @Sendable (_ token: String) -> Bool
    ) {
        self.rejection = rejection
        self.depositAddress = depositAddress
        self.rejects = rejects
    }

    func failNextVerifications(with errors: [RPCError]) {
        verifyFailures = errors
    }

    func setVerifyDelay(_ delay: Duration) {
        verifyDelay = delay
    }

    func issueChallenge() {
        challengesIssued += 1
    }

    /// The error the current `verify_challenge` fails with, if any.
    func nextVerifyFailure() -> RPCError? {
        verifyFailures.isEmpty ? nil : verifyFailures.removeFirst()
    }

    func issueToken() -> String {
        let token = "session-\(issuedTokens.count + 1)"
        issuedTokens.append(token)
        return token
    }

    func setClockOffset(_ offset: TimeInterval) {
        clockOffset = offset
    }

    /// The operator's current time, as its date header and token expiries state it.
    var now: Date {
        Date().addingTimeInterval(clockOffset)
    }

    /// The headers the operators' `TimestampHeaderInterceptor` adds to every successful answer.
    var timeHeaders: Metadata {
        var metadata = Metadata()
        metadata.addString(ServerClock.dateFormatter.string(from: now), forKey: "date")
        metadata.addString("1", forKey: "x-processing-time-ms")
        return metadata
    }

    func setSubscription(_ subscription: Subscription) {
        self.subscription = subscription
    }

    func setNodes(_ nodes: [Spark_TreeNode]) {
        self.nodes = nodes.sorted { $0.id < $1.id }
    }

    /// The page the operators return: every node without a limit, else at most 100 from `offset`.
    func nodesPage(limit: Int64, offset: Int64) -> [String: Spark_TreeNode] {
        nodePages.append([limit, offset])
        let start = min(Int(offset), nodes.count)
        let end = limit > 0 ? min(start + Int(min(limit, 100)), nodes.count) : nodes.count
        return Dictionary(uniqueKeysWithValues: nodes[start..<end].map { ($0.id, $0) })
    }

    func setTokenOutputs(_ outputs: [SparkToken_OutputWithPreviousTransactionData]) {
        tokenOutputs = outputs
    }

    func setFailsTokenMetadata(_ fails: Bool) {
        failsTokenMetadata = fails
    }

    func recordMetadataRequest(size: Int) {
        metadataRequestSizes.append(size)
    }

    func recordStart(_ transaction: SparkToken_TokenTransaction, idempotencyKey: String?) {
        startedSpends.append(transaction.transferInput.outputsToSpend.map {
            "\($0.prevTokenTransactionHash.hexString):\($0.prevTokenTransactionVout)"
        })
        startedTransactions.append((transaction, idempotencyKey))
    }

    func know(_ transfer: Spark_Transfer) {
        knownTransfers.append(transfer)
    }

    func hold(_ send: Spark_PreimageRequestWithTransfer) {
        heldSends.append(send)
    }

    func failPreimageSwaps(with error: RPCError) {
        preimageSwapError = error
    }

    func recordPreimageSwap(idempotencyKey: String) {
        preimageSwapIdempotencyKeys.append(idempotencyKey)
    }

    /// The SparkService methods called, in order.
    var methods: [String] {
        calls.map { String($0.prefix { $0 != " " }) }
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
        registerAuthn(with: &router)
        registerSparkService(with: &router)
        registerTransferMethods(with: &router)
        registerTokenService(with: &router)
    }

    /// Token outputs and metadata, with the operators' 500-identifier limit on metadata queries,
    /// and a `start_transaction` that records what it would spend and refuses.
    private func registerTokenService<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: SparkToken_SparkTokenService.Method.start_transaction.descriptor,
            deserializer: ProtobufDeserializer<SparkToken_StartTransactionRequest>(),
            serializer: ProtobufSerializer<SparkToken_StartTransactionResponse>()
        ) { [state] request, _ in
            guard await state.admit("start_transaction", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            let transaction = try await ServerRequest(stream: request).message.partialTokenTransaction
            await state.recordStart(transaction, idempotencyKey: request.metadata[stringValues: "x-idempotency-key"].first { _ in true })
            return StreamingServerResponse(error: RPCError(code: .failedPrecondition, message: "the fake operator starts nothing"))
        }
        router.registerHandler(
            forMethod: SparkToken_SparkTokenService.Method.query_token_outputs.descriptor,
            deserializer: ProtobufDeserializer<SparkToken_QueryTokenOutputsRequest>(),
            serializer: ProtobufSerializer<SparkToken_QueryTokenOutputsResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_token_outputs", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            var response = SparkToken_QueryTokenOutputsResponse()
            response.outputsWithPreviousTransactionData = await state.tokenOutputs
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: SparkToken_SparkTokenService.Method.query_token_metadata.descriptor,
            deserializer: ProtobufDeserializer<SparkToken_QueryTokenMetadataRequest>(),
            serializer: ProtobufSerializer<SparkToken_QueryTokenMetadataResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_token_metadata", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            let ids = try await ServerRequest(stream: request).message.tokenIdentifiers
            await state.recordMetadataRequest(size: ids.count)
            if await state.failsTokenMetadata {
                return StreamingServerResponse(error: RPCError(code: .internalError, message: "metadata unavailable"))
            }
            guard ids.count <= 500 else {
                return StreamingServerResponse(error: RPCError(
                    code: .invalidArgument, message: "too many token identifiers in filter: got \(ids.count), max 500"
                ))
            }
            var response = SparkToken_QueryTokenMetadataResponse()
            response.tokenMetadata = ids.map { id in
                var meta = SparkToken_TokenMetadata()
                meta.tokenIdentifier = id
                meta.tokenName = "Spam"
                meta.tokenTicker = "SPM"
                meta.maxSupply = Data(repeating: 0, count: 16)
                return meta
            }
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
    }

    /// The token-issuing service: every challenge verifies, and each session token is new.
    private func registerAuthn<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: SparkAuthn_SparkAuthnService.Method.get_challenge.descriptor,
            deserializer: ProtobufDeserializer<SparkAuthn_GetChallengeRequest>(),
            serializer: ProtobufSerializer<SparkAuthn_GetChallengeResponse>()
        ) { [state] _, _ in
            await state.issueChallenge()
            var response = SparkAuthn_GetChallengeResponse()
            response.protectedChallenge.challenge.nonce = Data(repeating: 7, count: 32)
            response.protectedChallenge.challenge.timestamp = Int64(await state.now.timeIntervalSince1970)
            return StreamingServerResponse(single: ServerResponse(message: response, metadata: await state.timeHeaders))
        }
        router.registerHandler(
            forMethod: SparkAuthn_SparkAuthnService.Method.verify_challenge.descriptor,
            deserializer: ProtobufDeserializer<SparkAuthn_VerifyChallengeRequest>(),
            serializer: ProtobufSerializer<SparkAuthn_VerifyChallengeResponse>()
        ) { [state] _, _ in
            try await Task.sleep(for: await state.verifyDelay)
            if let failure = await state.nextVerifyFailure() {
                return StreamingServerResponse(error: failure)
            }
            var response = SparkAuthn_VerifyChallengeResponse()
            response.sessionToken = await state.issueToken()
            response.expirationTimestamp = Int64(await state.now.addingTimeInterval(3_600).timeIntervalSince1970)
            return StreamingServerResponse(single: ServerResponse(message: response, metadata: await state.timeHeaders))
        }
    }

    private func registerSparkService<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: Spark_SparkService.Method.query_nodes.descriptor,
            deserializer: ProtobufDeserializer<Spark_QueryNodesRequest>(),
            serializer: ProtobufSerializer<Spark_QueryNodesResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_nodes", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            let query = try await ServerRequest(stream: request).message
            var response = Spark_QueryNodesResponse()
            response.nodes = await state.nodesPage(limit: query.limit, offset: query.offset)
            response.offset = -1
            return StreamingServerResponse(single: ServerResponse(message: response, metadata: await state.timeHeaders))
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
            forMethod: Spark_SparkService.Method.query_htlc.descriptor,
            deserializer: ProtobufDeserializer<Spark_QueryHtlcRequest>(),
            serializer: ProtobufSerializer<Spark_QueryHtlcResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_htlc", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            let query = try await ServerRequest(stream: request).message
            var response = Spark_QueryHtlcResponse()
            response.preimageRequests = await state.heldSends.filter { query.transferIds.contains($0.transfer.id) }
            response.offset = -1
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.query_all_transfers.descriptor,
            deserializer: ProtobufDeserializer<Spark_TransferFilter>(),
            serializer: ProtobufSerializer<Spark_QueryTransfersResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_all_transfers", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            var response = Spark_QueryTransfersResponse()
            response.offset = -1
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
    }

    /// Transfers, Lightning sends and the event subscription.
    private func registerTransferMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: Spark_SparkService.Method.query_pending_transfers.descriptor,
            deserializer: ProtobufDeserializer<Spark_TransferFilter>(),
            serializer: ProtobufSerializer<Spark_QueryTransfersResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_pending_transfers", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            return StreamingServerResponse(single: ServerResponse(message: Spark_QueryTransfersResponse()))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.query_transfers_by_id.descriptor,
            deserializer: ProtobufDeserializer<Spark_QueryTransfersByIdRequest>(),
            serializer: ProtobufSerializer<Spark_QueryTransfersResponse>()
        ) { [state] request, _ in
            guard await state.admit("query_transfers_by_id", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            let ids = Set(try await ServerRequest(stream: request).message.transferIds.map { $0.lowercased() })
            var response = Spark_QueryTransfersResponse()
            response.transfers = await state.knownTransfers.filter { ids.contains($0.id) }
            response.offset = -1
            return StreamingServerResponse(single: ServerResponse(message: response))
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.initiate_preimage_swap_v3.descriptor,
            deserializer: ProtobufDeserializer<Spark_InitiatePreimageSwapRequest>(),
            serializer: ProtobufSerializer<Spark_InitiatePreimageSwapResponse>()
        ) { [state] request, _ in
            guard await state.admit("initiate_preimage_swap_v3", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            await state.recordPreimageSwap(
                idempotencyKey: request.metadata[stringValues: "x-idempotency-key"].first { _ in true } ?? ""
            )
            return StreamingServerResponse(error: await state.preimageSwapError)
        }
        router.registerHandler(
            forMethod: Spark_SparkService.Method.subscribe_to_events.descriptor,
            deserializer: ProtobufDeserializer<Spark_SubscribeToEventsRequest>(),
            serializer: ProtobufSerializer<Spark_SubscribeToEventsResponse>()
        ) { [state] request, _ in
            guard await state.admit("subscribe_to_events", authorization: Self.authorization(request.metadata)) else {
                return await Self.reject(state)
            }
            let subscription = await state.subscription
            return StreamingServerResponse { writer in
                var event = Spark_SubscribeToEventsResponse()
                event.connected = Spark_ConnectedEvent()
                try await writer.write(event)
                if subscription == .heartbeatThenSilence {
                    var heartbeat = Spark_SubscribeToEventsResponse()
                    heartbeat.heartbeat = Spark_HeartbeatEvent()
                    try await writer.write(heartbeat)
                }
                if subscription != .end {
                    try await Task.sleep(for: .seconds(3))
                }
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
/// The wallet's SSP URL cannot be sent to, so any SSP call fails fast offline.
@discardableResult
func withFakeOperator<T: Sendable>(
    _ state: FakeOperatorState,
    _ body: (SparkWallet) async throws -> T
) async throws -> T {
    let transport = HTTP2ServerTransport.Posix(
        address: .ipv4(host: "127.0.0.1", port: 0),
        transportSecurity: .plaintext
    )
    let server = GRPCServer(transport: transport, services: [FakeOperator(state: state)])
    // Stopped abruptly rather than gracefully: a handler still writing to a stream the client has
    // reset can hold a graceful shutdown open indefinitely, and nothing waits on the server.
    let serving = Task { try await server.serve() }
    defer { serving.cancel() }
    let port = try #require(try await transport.listeningAddress.ipv4?.port)
    let config = SparkConfig(
        network: .regtest,
        signingOperators: [SigningOperatorConfig(
            address: "http://127.0.0.1:\(port)",
            identifier: "0000000000000000000000000000000000000000000000000000000000000001",
            identityPublicKeyHex: "03dfbdff4b6332c220f8fa2ba8ed496c698ceada563fa01b67d9983bfc5c95e763"
        )],
        // A scheme URLSession cannot send: every SSP call fails at once, without retries.
        sspURL: "unreachable://127.0.0.1/graphql",
        sspIdentityPublicKeyHex: "022bf283544b16c0622daecb79422007d167eca6ce9f0c98c0c49833b1f7170bfe"
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
