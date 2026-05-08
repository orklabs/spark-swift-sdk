# Changelog

All notable changes to SparkSDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the SDK is in `0.x`, the public API is considered unstable and minor releases may
contain breaking changes. Each breaking change will be documented under "Changed" with a
migration note.

---

## [Unreleased]

### Added
- `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and this `CHANGELOG.md`.
- `.env.example` and `Tests/SparkSDKTests/TestConfig.swift` for environment-driven test config.
- GitHub issue / pull request templates and Dependabot configuration.
- CI workflow (`.github/workflows/ci.yml`) running unit tests and lint on every PR.
- SwiftLint configuration (`.swiftlint.yml`).

### Changed
- Integration test mnemonics are now loaded from `SPARK_TEST_WALLET_*` environment variables
  or a gitignored `.env` file. Previously hardcoded mnemonics have been removed from source.
- `.gitignore` extended to cover `.env`, secrets directories, test artifacts, and DocC output.

### Security
- Removed funded-wallet mnemonics from the integration test source. **Anyone with access to
  prior git history should treat those mnemonics as compromised and rotate the funds.**

---

## [0.1.0] — TBD

Initial public release.

### Added
- `SparkWallet` core API with deposits, transfers, withdrawals, lightning send/receive,
  tokens, swaps, and event streaming.
- `SparkConfig` with mainnet and regtest defaults.
- `SparkError` typed error enum with localized descriptions.
- gRPC transport via `grpc-swift-2` and SSP GraphQL client.
- FROST threshold signing via `spark_frostFFI.xcframework` (Rust UniFFI).
- Test suite: BIP-39 vectors, key derivation, token validation, full integration coverage.

[Unreleased]: https://github.com/p-i-g-g-y/spark-swift-sdk/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/p-i-g-g-y/spark-swift-sdk/releases/tag/v0.1.0
