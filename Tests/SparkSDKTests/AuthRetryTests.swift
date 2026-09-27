import Foundation
import Testing
import GRPCCore
@testable import SparkSDK

/// The official SDK's auth middleware drops a token the operator rejects, authenticates again and
/// re-issues the call. These tests run the wallet's real transport stack against a local operator
/// stand-in. Before this fix, a header-less UNAUTHENTICATED made the interceptor call `next` a
/// second time on the same HTTP/2 stream, and swift-nio stopped the process with "allows only a
/// single AsyncIterator to be created".
@Suite("Session token rejection")
struct AuthRetryTests {

    @Test("A token the operator rejects before responding is dropped and the call re-issued with a fresh one",
          .timeLimit(.minutes(1)))
    func rejectedBeforeHeaders() async throws {
        let state = FakeOperatorState(rejection: .beforeHeaders) { $0 == "session-1" }
        let leaves = try await withFakeOperator(state) { wallet in
            try await wallet.getLeaves()
        }
        #expect(leaves.isEmpty)
        #expect(await state.issuedTokens == ["session-1", "session-2"])
        #expect(await state.calls == ["query_nodes Bearer session-1", "query_nodes Bearer session-2"])
    }

    @Test("A rejection sent after the response headers drops the token without re-sending the call",
          .timeLimit(.minutes(1)))
    func rejectedAfterHeaders() async throws {
        let state = FakeOperatorState(rejection: .afterHeaders) { $0 == "session-1" }
        try await withFakeOperator(state) { wallet in
            await #expect {
                _ = try await wallet.getLeaves()
            } throws: { ($0 as? RPCError)?.code == .unauthenticated }
            // The rejected token is gone: the next call authenticates again and succeeds.
            _ = try await wallet.getLeaves()
        }
        #expect(await state.issuedTokens == ["session-1", "session-2"])
        #expect(await state.calls == ["query_nodes Bearer session-1", "query_nodes Bearer session-2"])
    }

    @Test("A rejected event subscription ends cleanly and the next one uses a fresh token",
          .timeLimit(.minutes(1)))
    func rejectedSubscription() async throws {
        let state = FakeOperatorState(rejection: .beforeHeaders) { $0 == "session-1" }
        let (first, second) = try await withFakeOperator(state) { wallet in
            (try await Self.collect(wallet.subscribeToEvents()), try await Self.collect(wallet.subscribeToEvents()))
        }
        #expect(first.isEmpty)
        #expect(second.count == 1)
        if case .connected? = second.first {} else { Issue.record("expected a connected event, got \(second)") }
        #expect(await state.calls == ["subscribe_to_events Bearer session-1", "subscribe_to_events Bearer session-2"])
    }

    @Test("A token that is never accepted fails after the retry policy's attempts",
          .timeLimit(.minutes(1)))
    func rejectedEveryTime() async throws {
        let state = FakeOperatorState(rejection: .beforeHeaders) { _ in true }
        try await withFakeOperator(state) { wallet in
            await #expect {
                _ = try await wallet.getLeaves()
            } throws: { ($0 as? RPCError)?.code == .unauthenticated }
        }
        #expect(await state.issuedTokens == ["session-1", "session-2", "session-3"])
        #expect(await state.calls.count == Int(GrpcConnectionManager.retryPolicy.maxAttempts))
    }

    @Test("Calls without a token and the token-issuing service pass through untouched")
    func passThrough() async throws {
        let interceptor = AuthRetryInterceptor(
            currentToken: { Issue.record("no token should be fetched"); return "unexpected" },
            invalidate: { _ in Issue.record("nothing should be invalidated") }
        )
        let authn = ClientContext(
            descriptor: MethodDescriptor(fullyQualifiedService: AuthRetryInterceptor.authnService, method: "verify_challenge"),
            remotePeer: "", localPeer: ""
        )
        let spark = ClientContext(
            descriptor: MethodDescriptor(fullyQualifiedService: "spark.SparkService", method: "query_nodes"),
            remotePeer: "", localPeer: ""
        )
        for (context, metadata) in [(authn, ["authorization": "Bearer mine"] as Metadata), (spark, [:] as Metadata)] {
            var seen: [Metadata] = []
            let response: StreamingClientResponse<String> = try await interceptor.intercept(
                request: StreamingClientRequest(of: String.self, metadata: metadata) { _ in },
                context: context
            ) { request, _ in
                seen.append(request.metadata)
                return StreamingClientResponse(of: String.self, error: RPCError(code: .unauthenticated, message: "no"))
            }
            #expect(seen == [metadata])
            #expect((try? response.accepted.get()) == nil)
        }
    }

    /// Every event a subscription yields until it ends.
    static func collect(_ stream: AsyncStream<SparkEvent>) async -> [SparkEvent] {
        var events: [SparkEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}
