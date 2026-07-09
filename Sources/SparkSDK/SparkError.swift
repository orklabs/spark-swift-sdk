import Foundation

public enum SparkError: Swift.Error, LocalizedError, Sendable {
    case keyDerivationFailed
    case insufficientBalance(need: Int64, have: Int64)
    case authenticationFailed(String)
    case grpcError(String)
    case graphqlError(String)
    case invalidResponse(String)
    case frostSigningFailed(String)
    case notImplemented(String)
    case insufficientTokenBalance(token: String, need: String, have: String)
    case tokenValidationFailed(String)
    case leafTimelockExhausted(String)

    public var errorDescription: String? {
        switch self {
        case .keyDerivationFailed:
            return "Key derivation failed"
        case .insufficientBalance(let need, let have):
            return "Insufficient balance: need \(need) sats, have \(have) sats"
        case .authenticationFailed(let msg):
            return "Authentication failed: \(msg)"
        case .grpcError(let msg):
            return "gRPC error: \(msg)"
        case .graphqlError(let msg):
            return "GraphQL error: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .frostSigningFailed(let msg):
            return "FROST signing failed: \(msg)"
        case .notImplemented(let msg):
            return "Not implemented: \(msg)"
        case .insufficientTokenBalance(let token, let need, let have):
            return "Insufficient token balance for \(token): need \(need), have \(have)"
        case .tokenValidationFailed(let msg):
            return "Token validation failed: \(msg)"
        case .leafTimelockExhausted(let msg):
            return msg
        }
    }
}
