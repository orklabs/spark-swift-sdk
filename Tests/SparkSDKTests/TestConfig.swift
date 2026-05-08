import Foundation
import Testing

/// Loads integration test configuration from environment variables.
///
/// Integration tests require funded wallets on Spark mainnet. Mnemonics MUST NOT be
/// committed to source control. Configure them via environment variables, an `.env`
/// file in the repository root, or your CI's secret store.
///
/// Required variables:
///   - `SPARK_TEST_WALLET_A_MNEMONIC` — funded wallet used as the primary test wallet
///   - `SPARK_TEST_WALLET_B_MNEMONIC` — second wallet for transfer/receive flows
///
/// Optional variables:
///   - `SPARK_TEST_STATIC_DEPOSIT_MNEMONIC` — wallet with a funded static deposit
///   - `SPARK_TEST_STATIC_DEPOSIT_ADDRESS` — address with confirmed UTXOs
///   - `SPARK_TEST_STATIC_DEPOSIT_TXID` — claimable static deposit txid
///   - `SPARK_TEST_STATIC_DEPOSIT_WITHDRAW_ADDRESS` — destination for withdraw fee tests
///   - `SPARK_TEST_LIGHTNING_ADDRESS` — external LN address for paid invoice tests
///
/// Example `.env` (gitignored):
/// ```
/// SPARK_TEST_WALLET_A_MNEMONIC="word1 word2 ... word12"
/// SPARK_TEST_WALLET_B_MNEMONIC="word1 word2 ... word12"
/// ```
enum TestConfig {

    /// Lazy-loaded `.env` contents, parsed once per test process.
    private static let dotEnv: [String: String] = loadDotEnv()

    /// `true` when both required wallet mnemonics are configured. Use this with
    /// `@Suite(.enabled(if: TestConfig.hasIntegrationCredentials))` to skip
    /// integration suites in CI environments that lack funded test wallets.
    static var hasIntegrationCredentials: Bool {
        guard let a = optional("SPARK_TEST_WALLET_A_MNEMONIC"), !a.isEmpty,
              let b = optional("SPARK_TEST_WALLET_B_MNEMONIC"), !b.isEmpty
        else { return false }
        return true
    }

    /// Primary funded wallet used by most integration tests.
    static var walletAMnemonic: String {
        require("SPARK_TEST_WALLET_A_MNEMONIC")
    }

    /// Secondary wallet for transfer/receive flows.
    static var walletBMnemonic: String {
        require("SPARK_TEST_WALLET_B_MNEMONIC")
    }

    /// Wallet that owns a funded static deposit. Optional — tests skip if absent.
    static var staticDepositMnemonic: String? {
        optional("SPARK_TEST_STATIC_DEPOSIT_MNEMONIC")
    }

    static var staticDepositAccount: Int {
        Int(optional("SPARK_TEST_STATIC_DEPOSIT_ACCOUNT") ?? "11") ?? 11
    }

    static var staticDepositAddress: String? {
        optional("SPARK_TEST_STATIC_DEPOSIT_ADDRESS")
    }

    static var staticDepositTxid: String? {
        optional("SPARK_TEST_STATIC_DEPOSIT_TXID")
    }

    static var staticDepositWithdrawAddress: String? {
        optional("SPARK_TEST_STATIC_DEPOSIT_WITHDRAW_ADDRESS")
    }

    static var externalLightningAddress: String? {
        optional("SPARK_TEST_LIGHTNING_ADDRESS")
    }

    // MARK: - Internals

    private static func require(_ key: String) -> String {
        if let value = optional(key), !value.isEmpty {
            return value
        }
        Issue.record("""
        Missing required environment variable \(key).

        Integration tests need funded test wallets. Set this in your shell, in a
        gitignored `.env` file at the repo root, or in your CI secret store.

        See Tests/SparkSDKTests/TestConfig.swift for the full list of variables.
        """)
        return ""
    }

    private static func optional(_ key: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
            return env
        }
        return dotEnv[key]
    }

    /// Minimal `.env` parser. Supports `KEY=value` and `KEY="value with spaces"`.
    /// Lines starting with `#` and blank lines are ignored.
    private static func loadDotEnv() -> [String: String] {
        let candidates = [
            ProcessInfo.processInfo.environment["SPARK_TEST_DOTENV"],
            findRepoRoot()?.appendingPathComponent(".env").path,
            FileManager.default.currentDirectoryPath + "/.env",
        ].compactMap { $0 }

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path),
                  let contents = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            return parseDotEnv(contents)
        }
        return [:]
    }

    /// Walk up from the current file to find the directory containing `Package.swift`.
    private static func findRepoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func parseDotEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding single or double quotes.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'")  && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
