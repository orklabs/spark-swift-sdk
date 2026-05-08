import Foundation
import GRPCCore

/// Header name used for gRPC idempotency keys.
let idempotencyKeyHeader = "x-idempotency-key"

/// Add an idempotency key to existing gRPC metadata.
func metadataWithIdempotencyKey(_ key: String, base: Metadata = [:]) -> Metadata {
    var metadata = base
    metadata.addString(key, forKey: idempotencyKeyHeader)
    return metadata
}

/// Options for operations that support idempotency.
public struct IdempotencyOptions: Sendable {
    /// Client-provided idempotency key for deduplication.
    /// Multiple requests with the same key return the same result
    /// instead of creating duplicates or errors.
    public let idempotencyKey: String?

    public init(idempotencyKey: String? = nil) {
        self.idempotencyKey = idempotencyKey
    }
}
