import Foundation
import secp256k1

/// Spark addresses: a bech32m encoding of the protobuf `SparkAddress` payload under a
/// network-specific human-readable part. A plain address carries only `identity_public_key`; a
/// Spark invoice also carries `spark_invoice_fields` and the receiver's signature.
enum SparkAddress {
    /// Current prefix plus the legacy one the reference SDK still accepts.
    private static func prefixes(for network: SparkNetwork) -> (current: String, legacy: String) {
        switch network {
        case .mainnet: return ("spark", "sp")
        case .regtest: return ("sparkrt", "sprt")
        }
    }

    static func hrp(for network: SparkNetwork) -> String {
        prefixes(for: network).current
    }

    static func encode(identityPublicKey: Data, network: SparkNetwork) -> String {
        // Protobuf wire encoding: field 1, wire type 2 (tag 0x0a), single-byte length, bytes.
        var payload = Data([0x0a, UInt8(identityPublicKey.count)])
        payload.append(identityPublicKey)
        return Bech32m.encode(hrp: hrp(for: network), data: Bech32.toWords(payload))
    }

    /// A decoded Spark address or Spark invoice.
    struct Payload: Sendable {
        let identityPublicKey: Data
        /// Present when the string is a Spark invoice: what to pay (sats or tokens, and how much),
        /// until when, from whom, with a memo.
        let invoiceFields: Spark_SparkInvoiceFields?
        /// The receiver's signature over an invoice.
        let signature: Data?
    }

    /// Decode the whole `SparkAddress` payload of a Spark address or Spark invoice, as the
    /// reference SDK's `decodeSparkAddress` does. Throws `SparkError.invalidAddress` for a
    /// malformed string, one for another network, or an identity key that is not a compressed
    /// secp256k1 point.
    static func decodePayload(_ address: String, network: SparkNetwork) throws -> Payload {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hrp: String
        let words: [UInt8]
        do {
            (hrp, words) = try Bech32m.decodeBech32m(trimmed)
        } catch let error as SparkError {
            throw SparkError.invalidAddress("'\(trimmed)': \(error.localizedDescription)")
        }
        let allowed = prefixes(for: network)
        guard hrp == allowed.current || hrp == allowed.legacy else {
            throw SparkError.invalidAddress("'\(trimmed)' is not a \(network) Spark address (prefix '\(hrp)')")
        }
        guard let bytes = Bech32.fromWords(words),
              let payload = try? Spark_SparkAddress(serializedBytes: bytes) else {
            throw SparkError.invalidAddress("'\(trimmed)' has an invalid payload encoding")
        }
        guard payload.identityPublicKey.count == 33,
              (try? secp256k1.Signing.PublicKey(dataRepresentation: payload.identityPublicKey, format: .compressed)) != nil else {
            throw SparkError.invalidAddress("'\(trimmed)' does not carry a valid 33-byte identity public key")
        }
        return Payload(
            identityPublicKey: payload.identityPublicKey,
            invoiceFields: payload.hasSparkInvoiceFields ? payload.sparkInvoiceFields : nil,
            signature: payload.hasSignature ? payload.signature : nil
        )
    }

    /// The identity public key a plain Spark address encodes. Throws `SparkError.invalidAddress`
    /// for a malformed address, one for another network, or a Spark invoice: paying an invoice as
    /// if it were an address ignores its amount, expiry and sender restriction, and the transfer
    /// is not linked to it, so the payee never sees it paid (the reference SDK's `transfer` and
    /// `transferTokens` refuse invoices too).
    static func decode(_ address: String, network: SparkNetwork) throws -> Data {
        let payload = try decodePayload(address, network: network)
        guard payload.invoiceFields == nil else {
            throw SparkError.invalidAddress(
                "this is a Spark invoice, not a Spark address; paying it as an address would ignore its amount, expiry and sender"
            )
        }
        return payload.identityPublicKey
    }
}
