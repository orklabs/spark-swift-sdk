import Foundation
import Testing
import GRPCCore
@testable import SparkSDK

/// Pins the transport behaviour that stops a wedged connection or a rejected session token from
/// parking every call until the host process restarts — the values mirror the official Spark
/// SDK's connection manager (60 s unary cap; 3 attempts, 1 s → 10 s backoff on UNAVAILABLE and
/// CANCELLED; re-authenticate and re-issue a call rejected as UNAUTHENTICATED).
@Suite("Transport hardening")
struct TransportHardeningTests {

    private var global: MethodConfig? {
        GrpcConnectionManager.serviceConfig.methodConfig.first {
            $0.names.contains(MethodConfig.Name(service: "", method: ""))
        }
    }

    @Test("Every RPC carries the official 60 s deadline")
    func defaultDeadline() {
        #expect(global?.timeout == GrpcConnectionManager.defaultRPCTimeout)
        #expect(GrpcConnectionManager.defaultRPCTimeout == .seconds(60))
    }

    @Test("Every RPC retries like the official SDK: 3 attempts, 1 s to 10 s, UNAVAILABLE, CANCELLED and UNAUTHENTICATED")
    func retryPolicy() {
        guard let policy = global?.executionPolicy?.retry else {
            Issue.record("no retry policy on the global method config")
            return
        }
        #expect(policy.maxAttempts == 3)
        #expect(policy.initialBackoff == .seconds(1))
        #expect(policy.maxBackoff == .seconds(10))
        #expect(policy.backoffMultiplier == 2)
        #expect(policy.retryableStatusCodes == Set<Status.Code>([.unavailable, .cancelled, .unauthenticated]))
        #expect(!policy.retryableStatusCodes.contains(Status.Code.deadlineExceeded))
    }

    @Test("Messages up to the reference SDK's 20 MB are sent and received, the event stream included")
    func messageSizeLimit() {
        let stream = GrpcConnectionManager.serviceConfig.methodConfig.first {
            $0.names.contains(MethodConfig.Name(service: "spark.SparkService", method: "subscribe_to_events"))
        }
        #expect(GrpcConnectionManager.maxMessageBytes == 20 * 1024 * 1024)
        for config in [global, stream] {
            #expect(config?.maxRequestMessageBytes == GrpcConnectionManager.maxMessageBytes)
            #expect(config?.maxResponseMessageBytes == GrpcConnectionManager.maxMessageBytes)
        }
    }

    static func availableNode(_ index: Int, payload: Int = 0) -> Spark_TreeNode {
        var node = Spark_TreeNode()
        node.id = String(format: "node-%04d", index)
        node.status = "AVAILABLE"
        node.value = 1
        node.nodeTx = Data(repeating: 0xAB, count: payload)
        return node
    }

    @Test("A wallet's nodes are read a page of 100 at a time until a short page", .timeLimit(.minutes(1)))
    func nodePaging() async throws {
        let state = FakeOperatorState { _ in false }
        await state.setNodes((0..<250).map { Self.availableNode($0) })
        let leaves = try await withFakeOperator(state) { wallet in try await wallet.getLeaves() }
        #expect(leaves.count == 250)
        #expect(await state.nodePages == [[100, 0], [100, 100], [100, 200]])
    }

    @Test("A page larger than gRPC's 4 MiB default is received", .timeLimit(.minutes(1)))
    func largePage() async throws {
        let state = FakeOperatorState { _ in false }
        // 100 nodes of 50 kB: one 5 MB page, then an empty one.
        await state.setNodes((0..<100).map { Self.availableNode($0, payload: 50_000) })
        let leaves = try await withFakeOperator(state) { wallet in try await wallet.getLeaves() }
        #expect(leaves.count == 100)
        #expect(await state.nodePages == [[100, 0], [100, 100]])
    }

    @Test("The event subscription stream is unbounded and never retried by the transport")
    func eventStreamUnbounded() {
        let stream = GrpcConnectionManager.serviceConfig.methodConfig.first {
            $0.names.contains(MethodConfig.Name(service: "spark.SparkService", method: "subscribe_to_events"))
        }
        #expect(stream != nil)
        #expect(stream?.timeout == nil)
        #expect(stream?.executionPolicy == nil)
    }

    @Test("The auth interceptor leaves the token-issuing service alone, and the transport never retries it")
    func authnServiceIsExempt() {
        #expect(AuthRetryInterceptor.authnService == "spark_authn.SparkAuthnService")
        let authn = GrpcConnectionManager.serviceConfig.methodConfig.first {
            $0.names.contains(MethodConfig.Name(service: "spark_authn.SparkAuthnService", method: ""))
        }
        #expect(authn != nil)
        #expect(authn?.executionPolicy == nil)
        #expect(authn?.timeout == GrpcConnectionManager.defaultRPCTimeout)
    }

    @Test("SSP amounts are read in their reported unit; other units are refused")
    func currencyAmounts() throws {
        func amount(_ value: Any, _ unit: String?) -> [String: Any] {
            var object: [String: Any] = ["original_value": value]
            if let unit { object["original_unit"] = unit }
            return object
        }
        // As the SSP's JSON arrives: numbers are NSNumbers.
        let decoded = try JSONSerialization.jsonObject(with: Data(#"{"original_value": 2000, "original_unit": "MILLISATOSHI"}"#.utf8))
        #expect(try SspCurrencyAmount.sats(decoded as? [String: Any], field: "fee") == 2)
        #expect(try SspCurrencyAmount.sats(amount(Int64(2), "SATOSHI"), field: "fee") == 2)
        #expect(try SspCurrencyAmount.sats(amount(Int64(2001), "MILLISATOSHI"), field: "fee") == 3)
        #expect(try SspCurrencyAmount.sats(amount(Int64(0), "MILLISATOSHI"), field: "fee") == 0)
        for bad in [amount(Int64(1), "BITCOIN"), amount(Int64(1), "USD"), amount(Int64(1), nil),
                    amount(Int64(-1), "SATOSHI"), amount("12", "SATOSHI")] {
            #expect(throws: SparkError.self) { _ = try SspCurrencyAmount.sats(bad, field: "fee") }
        }
        #expect(throws: SparkError.self) { _ = try SspCurrencyAmount.sats(nil, field: "fee") }
        #expect(GraphQLQueries.lightningSendFeeEstimate.contains("original_unit"))
    }

    @Test("An SSP auth rejection is recognised, other failures are not")
    func sspAuthFailureClassifier() {
        #expect(SspGraphQLClient.isAuthFailure(.graphqlError("HTTP 401")))
        #expect(SspGraphQLClient.isAuthFailure(.graphqlError("HTTP 403")))
        #expect(SspGraphQLClient.isAuthFailure(.graphqlError("Unauthorized")))
        #expect(SspGraphQLClient.isAuthFailure(.graphqlError("Not authenticated: token expired")))
        #expect(!SspGraphQLClient.isAuthFailure(.graphqlError("HTTP 500")))
        #expect(!SspGraphQLClient.isAuthFailure(.graphqlError("Insufficient funds for coop exit")))
        #expect(!SspGraphQLClient.isAuthFailure(.invalidResponse("Invalid fee estimate response")))
    }

    @Test("The operators' clock is estimated from their date and processing-time headers")
    func serverClock() throws {
        let clock = ServerClock()
        #expect(!clock.isSynced)
        #expect(abs(clock.now().timeIntervalSinceNow) < 1)
        // Garbage headers are ignored.
        clock.record(date: "yesterday", processingTime: "1", sent: .now, received: .now)
        clock.record(date: "Mon, 02 Jan 2006 15:04:05 UTC", processingTime: "-5", sent: .now, received: .now)
        #expect(!clock.isSynced)

        // Answered 200 ms after sending, 100 ms of it processing: 50 ms each way.
        let received = ContinuousClock.now
        clock.record(
            date: "Mon, 02 Jan 2006 15:04:05 UTC", processingTime: "100",
            sent: received - .milliseconds(200), received: received
        )
        #expect(clock.isSynced)
        let stated = try #require(ServerClock.dateFormatter.date(from: "Mon, 02 Jan 2006 15:04:05 UTC"))
        #expect(stated == Date(timeIntervalSince1970: 1_136_214_245))
        let offset = clock.now().timeIntervalSince(stated)
        #expect(offset >= 0.05 && offset < 1.05)
    }

    @Test("Session tokens are kept by the operator's clock: a device clock two hours ahead does not re-authenticate every call",
          .timeLimit(.minutes(1)))
    func skewedDeviceClock() async throws {
        let state = FakeOperatorState { _ in false }
        await state.setClockOffset(-2 * 3_600)
        try await withFakeOperator(state) { wallet in
            for _ in 0..<3 {
                _ = try await wallet.getLeaves()
            }
            #expect(abs(wallet.serverClock.now().timeIntervalSinceNow + 2 * 3_600) < 5)
        }
        #expect(await state.issuedTokens == ["session-1"])
    }

    @Test("On mainnet the operators' answers set the clock, close to this machine's",
          .enabled(if: TestConfig.hasIntegrationCredentials), .timeLimit(.minutes(1)))
    func mainnetServerClock() async throws {
        let wallet = try await makeWallet(TestConfig.walletBMnemonic)
        defer { Task { await wallet.close() } }
        _ = try await wallet.getLeaves()
        #expect(wallet.serverClock.isSynced)
        let skew = wallet.serverClock.now().timeIntervalSinceNow
        #expect(abs(skew) < 10)
        print("operators' clock is \(String(format: "%.2f", skew)) s from this machine's")
    }
}
