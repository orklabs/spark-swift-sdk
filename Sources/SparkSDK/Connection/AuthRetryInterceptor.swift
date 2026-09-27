import Foundation
import GRPCCore

/// Keeps operator calls on a live session token, like the official SDK's auth middleware, without
/// ever touching an RPC's stream twice.
///
/// - Every attempt of a call that carries an `authorization` header is sent with the operator's
///   current token: the cached one, or a freshly authenticated one after an invalidation.
/// - An UNAUTHENTICATED answer drops that token (if it is still the cached one), so the next
///   attempt authenticates again. The transport's retry policy lists UNAUTHENTICATED: a call the
///   operator rejects before sending response headers — how its auth interceptor answers — is
///   re-issued on a new stream with the new token. A rejection that arrives after the headers
///   fails this call and heals the next one.
///
/// `next` must be called exactly once. In grpc-swift 2 it is bound to the attempt's single HTTP/2
/// stream; calling it again asks that stream for a second response iterator, which swift-nio
/// treats as a fatal error — the app would crash instead of re-authenticating. The operator
/// returns `codes.Unauthenticated` only from its pre-handler interceptors, so nothing has run
/// server-side when a call is re-issued.
struct AuthRetryInterceptor: ClientInterceptor {
    /// The service that issues the tokens; its own calls never carry one.
    static let authnService = "spark_authn.SparkAuthnService"

    /// The operator's current session token: cached, or newly authenticated after `invalidate`.
    let currentToken: @Sendable () async throws -> String
    /// Drops `token` from the cache if it is still the operator's current one. A late rejection of
    /// an older token must not evict the new token another call already obtained.
    let invalidate: @Sendable (_ token: String) async -> Void

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        guard context.descriptor.service.fullyQualifiedService != Self.authnService,
              Self.isAuthenticated(request.metadata) else {
            return try await next(request, context)
        }
        let token = try await currentToken()
        var request = request
        request.metadata.replaceOrAddString("Bearer \(token)", forKey: "authorization")

        let response: StreamingClientResponse<Output>
        do {
            response = try await next(request, context)
        } catch let error as RPCError where error.code == .unauthenticated {
            await invalidate(token)
            throw error
        }

        switch response.accepted {
        case .failure(let error):
            if error.code == .unauthenticated {
                await invalidate(token)
            }
            return response
        case .success(var contents):
            let invalidate = self.invalidate
            contents.bodyParts = RPCAsyncSequence(
                wrapping: UnauthenticatedObserver(base: contents.bodyParts) { await invalidate(token) }
            )
            return StreamingClientResponse(accepted: .success(contents))
        }
    }

    /// Whether the call site asked for an authenticated call (it attached a bearer token).
    static func isAuthenticated(_ metadata: Metadata) -> Bool {
        metadata[stringValues: "authorization"].contains { _ in true }
    }
}

/// Passes a response body through unchanged and calls `onUnauthenticated` when it ends with an
/// UNAUTHENTICATED status, i.e. a rejection the operator sent after the response headers.
struct UnauthenticatedObserver<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Base.Element: Sendable {
    typealias Element = Base.Element

    let base: Base
    let onUnauthenticated: @Sendable () async -> Void

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let onUnauthenticated: @Sendable () async -> Void

        mutating func next() async throws -> Element? {
            do {
                return try await base.next()
            } catch let error as RPCError where error.code == .unauthenticated {
                await onUnauthenticated()
                throw error
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), onUnauthenticated: onUnauthenticated)
    }
}
