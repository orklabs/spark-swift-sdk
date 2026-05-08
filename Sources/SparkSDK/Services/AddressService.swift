import Foundation

extension SparkWallet {
    /// Get the Spark address for this wallet (bech32m-encoded identity public key).
    /// Format: `spark1...` for mainnet, `sparkrt1...` for regtest.
    public func getSparkAddress() -> String {
        let prefix: String
        switch config.network {
        case .mainnet: prefix = "spark"
        case .regtest: prefix = "sparkrt"
        }

        // Protobuf wire encoding: field 1 (identity_public_key), wire type 2 (length-delimited)
        // Tag = (1 << 3) | 2 = 10, then length, then bytes
        let pubkey = signer.identityPublicKey
        var payload = Data()
        payload.append(UInt8(10)) // field 1, wire type 2
        payload.append(UInt8(pubkey.count))
        payload.append(pubkey)

        let words = Bech32m.toWords(payload)
        return Bech32m.encode(hrp: prefix, data: words)
    }
}
