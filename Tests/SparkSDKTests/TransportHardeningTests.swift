import Foundation
import Testing
import GRPCCore
@testable import SparkSDK

/// Pins the transport behaviour that stops a wedged connection or a rejected session token from
/// parking every call until the host process restarts — the values mirror the official Spark
/// SDK's connection manager (60 s unary cap; 3 attempts, 1 s → 10 s backoff on UNAVAILABLE and
/// CANCELLED; re-authenticate and replay once on an expired token).
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

    @Test("Every RPC retries like the official SDK: 3 attempts, 1 s to 10 s, UNAVAILABLE and CANCELLED")
    func retryPolicy() {
        guard let policy = global?.executionPolicy?.retry else {
            Issue.record("no retry policy on the global method config")
            return
        }
        #expect(policy.maxAttempts == 3)
        #expect(policy.initialBackoff == .seconds(1))
        #expect(policy.maxBackoff == .seconds(10))
        #expect(policy.backoffMultiplier == 2)
        #expect(policy.retryableStatusCodes == Set<Status.Code>([.unavailable, .cancelled]))
        #expect(!policy.retryableStatusCodes.contains(Status.Code.deadlineExceeded))
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

    @Test("The auth interceptor leaves the token-issuing service alone")
    func authnServiceIsExempt() {
        #expect(AuthRetryInterceptor.authnService == "spark_authn.SparkAuthnService")
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
}
