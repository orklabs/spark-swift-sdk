import Foundation
import GRPCCore

/// Re-authenticates and replays a call ONCE when an operator answers UNAUTHENTICATED — the
/// official Spark SDK's auth middleware behaviour ("token has expired" → drop the cached token,
/// authenticate again, re-issue the call with the new token).
///
/// `SparkAuthenticator` caches a session token until its `expiresAt`; if the operator stops
/// honouring it before then (restart, rotation, a forgotten session) the same rejected token
/// would otherwise be replayed on every call — and every call would fail — until the process
/// restarts. The operator returns `codes.Unauthenticated` for every token problem, so the status
/// code is matched rather than the message. A second rejection is returned as is.
struct AuthRetryInterceptor: ClientInterceptor {
    /// The service that issues the tokens; its own calls never carry one.
    static let authnService = "spark_authn.SparkAuthnService"

    /// Drops this operator's cached session and returns a fresh token.
    let refreshToken: @Sendable () async throws -> String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        if context.descriptor.service.fullyQualifiedService == Self.authnService {
            return try await next(request, context)
        }
        let response: StreamingClientResponse<Output>
        do {
            response = try await next(request, context)
        } catch let error as RPCError where error.code == .unauthenticated {
            return try await replay(request, context, next)
        }
        if case .failure(let error) = response.accepted, error.code == .unauthenticated {
            return try await replay(request, context, next)
        }
        return response
    }

    private func replay<Input: Sendable, Output: Sendable>(
        _ request: StreamingClientRequest<Input>,
        _ context: ClientContext,
        _ next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let token = try await refreshToken()
        var retried = request
        retried.metadata.replaceOrAddString("Bearer \(token)", forKey: "authorization")
        return try await next(retried, context)
    }
}
