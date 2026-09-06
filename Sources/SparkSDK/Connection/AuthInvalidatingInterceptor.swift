import Foundation
import GRPCCore

/// Drops the cached operator session tokens the moment an operator answers UNAUTHENTICATED.
///
/// `SparkAuthenticator` caches a session token until its `expiresAt`; if the operator stops
/// honouring it before then (restart, rotation, a forgotten session) the same rejected token
/// would otherwise be replayed on every call — and every call would fail — until the process
/// restarts. This interceptor only observes: the failing call still fails, but the NEXT call
/// authenticates afresh. (Callers that retry — a balance refresh, a kill quote's "check again" —
/// therefore recover on their own.)
struct AuthInvalidatingInterceptor: ClientInterceptor {
    let authenticator: SparkAuthenticator

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let response: StreamingClientResponse<Output>
        do {
            response = try await next(request, context)
        } catch let error as RPCError where error.code == .unauthenticated {
            await authenticator.invalidateAll()
            throw error
        }
        if case .failure(let error) = response.accepted, error.code == .unauthenticated {
            await authenticator.invalidateAll()
        }
        return response
    }
}
