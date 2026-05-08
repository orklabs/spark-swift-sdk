import Foundation
import GRPCCore

extension SparkWallet {

    /// Enable or disable privacy mode.
    /// When enabled, transaction history becomes invisible from public endpoints and block explorers.
    public func setPrivacyEnabled(_ enabled: Bool) async throws -> WalletSettings {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = Spark_UpdateWalletSettingRequest()
        request.privateEnabled = enabled

        let response = try await client.update_wallet_setting(
            request: ClientRequest(message: request, metadata: metadata)
        )

        let setting = response.walletSetting
        return WalletSettings(
            privateEnabled: setting.privateEnabled,
            ownerIdentityPublicKey: Data(setting.ownerIdentityPublicKey).hexString
        )
    }

    /// Query current wallet settings, including privacy mode status.
    public func getWalletSettings() async throws -> WalletSettings {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        let response = try await client.query_wallet_setting(
            request: ClientRequest(message: Spark_QueryWalletSettingRequest(), metadata: metadata)
        )

        let setting = response.walletSetting
        return WalletSettings(
            privateEnabled: setting.privateEnabled,
            ownerIdentityPublicKey: Data(setting.ownerIdentityPublicKey).hexString
        )
    }
}
