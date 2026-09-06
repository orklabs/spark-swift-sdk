import Foundation
import Testing
import GRPCCore
@testable import SparkSDK

/// Pins the transport hardening that stops a wedged connection or a rejected session token from
/// parking every call until the host process restarts.
@Suite("Transport hardening")
struct TransportHardeningTests {

    @Test("Every RPC carries the default deadline")
    func defaultDeadline() {
        let global = GrpcConnectionManager.serviceConfig.methodConfig.first {
            $0.names.contains(MethodConfig.Name(service: "", method: ""))
        }
        #expect(global?.timeout == GrpcConnectionManager.defaultRPCTimeout)
        #expect(GrpcConnectionManager.defaultRPCTimeout == .seconds(60))
    }

    @Test("The event subscription stream stays unbounded")
    func eventStreamUnbounded() {
        let stream = GrpcConnectionManager.serviceConfig.methodConfig.first {
            $0.names.contains(MethodConfig.Name(service: "spark.SparkService", method: "subscribe_to_events"))
        }
        #expect(stream != nil)
        #expect(stream?.timeout == nil)
    }

    @Test("Connections drop when idle and ping only under a live call, under server ping policy")
    func connectionHygiene() {
        let connection = GrpcConnectionManager.transportConfig.connection
        #expect(connection.maxIdleTime == .seconds(300))
        #expect(connection.keepalive?.allowWithoutCalls == false)
        #expect(connection.keepalive.map { $0.time >= .seconds(300) } == true)
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
