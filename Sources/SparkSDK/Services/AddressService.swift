import Foundation

extension SparkWallet {
    /// Get the Spark address for this wallet (bech32m-encoded identity public key).
    /// Format: `spark1...` for mainnet, `sparkrt1...` for regtest.
    public func getSparkAddress() -> String {
        SparkAddress.encode(identityPublicKey: signer.identityPublicKey, network: config.network)
    }
}
