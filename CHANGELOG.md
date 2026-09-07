# Changelog

All notable changes to SparkSDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the SDK is in `0.x`, the public API is considered unstable and minor releases may
contain breaking changes. Each breaking change will be documented under "Changed" with a
migration note.

---

## [Unreleased]

Nothing yet.

---

## [0.2.1] — 2026-09-07

### Added
- `SatsBalance.locked`: sats held by an in-flight transfer, swap, renewal or exit
  (`owned - available - frozen`), the figure `WithdrawAllQuote.lockedSats` and
  `WithdrawAllResult.lockedSats` already reported.

### Changed
- Internal cleanup of the 0.2.0 hardening work, with no behaviour change: removed the unused
  greedy leaf selector and invoice rounding helper, shared the claim/renew/quote prelude between
  `quoteWithdrawAll` and `withdrawAll`, replaced dictionary force-unwraps in Spark address and
  key-tweak handling with a switch and index-paired shares, reduced `Bech32m` to a thin
  bech32m-only layer over `Bech32`, and made invoice creation use the configured signing
  threshold instead of recomputing it.

### Fixed
- README quick start showed the removed `send(receiverIdentityPublicKey:)` call; it now uses
  `send(receiverSparkAddress:)`.
- Stale comments: the `withdraw` leaf-selection note referred to a `withdraw_all` step that no
  longer exists, and the refund-timelock doc said floor leaves could move "until renewed" when
  the coordinator will not renew them either.

---

## [0.2.0] — 2026-09-07

### Security
- `withdraw` verifies the SSP's cooperative-exit response before signing: the raw exit
  transaction must hash to the reported txid, pay the destination at least `amount - fee`, and
  the connector transaction must spend it. Leaves are swapped to exactly `amountSats` first, so
  a partial withdrawal can no longer send the full value of an oversized leaf. Fees are bounded
  by a new optional `maxFeeSats` (default: the SSP's own quote).
- `payLightningInvoice` now requires `maxFeeSats` and refuses a higher SSP estimate. Invoices
  are decoded by a BOLT-11 parser that verifies the checksum, enforces the wallet's network and
  handles hostile amounts without trapping. A caller amount is only accepted for amountless
  invoices. Failures after the coordinator locked leaves throw
  `SparkError.lightningSendIncomplete(transferId:)`; pass `transferId:` to resume.
- `createLightningInvoice` verifies the SSP-returned invoice (payment hash, amount, network)
  before storing preimage shares.
- Inbound transfer claims verify the sender's signature on every leaf, and that the transfer is
  addressed to this wallet, before any secret is decrypted.
- Token commits verify the coordinator's final transaction against the submitted partial
  transaction (inputs, outputs, amounts, owners, operator keys, withdraw bond and locktime,
  keyshare info).
- The coordinator's operator list is reconciled with the local configuration; secret shares
  are encrypted only to configured operator keys.
- Mnemonics are validated against the BIP-39 English wordlist and checksum
  (`SparkError.invalidMnemonic`); pass `validateMnemonic: false` to opt out.
- Raw transactions from operators, the SSP and the block explorer are parsed with bounds checks
  (`SparkError.malformedTransaction`) instead of unchecked indexing that could crash the app.
- Spending paths (`send`, `payLightningInvoice`, `withdraw`, swaps) renew leaves whose refund
  timelock is in [100, 200) before selecting, and never select leaves at the timelock floor, so
  one stuck leaf cannot fail a payment other leaves could cover. `renewExhaustedLeaves` reports
  leaves below the coordinator's renewal minimum (100) without a round trip; those can only be
  recovered by a unilateral exit.
- `withdraw` speaks the cooperative-exit protocol the coordinator requires today: the
  connector-input refund transactions are FROST-signed by the user and sent together with the
  key-tweak package in a single `cooperative_exit_v2` call. The previous two-step form (unsigned
  jobs, then `finalize_transfer_with_transfer_package`) is rejected by mainnet with
  "transfer_package is required for cooperative exit". Verified on mainnet.

### Added
- `SatsBalance.frozen`: sats in AVAILABLE leaves at the timelock floor. They are no longer counted
  in `available`, which now means "can be sent right now", so sending the full `available`
  balance always succeeds.
- `withdrawAll(onChainAddress:maxFeeSats:)` and `quoteWithdrawAll(onChainAddress:)`: claim pending
  transfers, renew renewable leaves, and exit every spendable leaf in one cooperative exit. The
  result reports the verified payout, the fee the SSP took, and the frozen, locked and unclaimed
  sats that stayed behind; the quote reports the same up front with `frozenFraction` for
  product decisions.
- `getSpendableLeaves()`: the leaves every spend path selects from (renews what the coordinator
  will renew, excludes frozen leaves), plus `SparkLeaf.isSpendable` and `isRenewable`. Use it, or
  `satsBalance.available`, as the basis for a "send everything" amount.
- `send(receiverSparkAddress:amountSats:)` with network-checked Spark address decoding.
- `SparkConfig.signingThreshold`, `expectedWithdrawBondSats`, `expectedWithdrawRelativeBlockLocktime`.
- `SparkError` cases: `invalidArgument`, `malformedTransaction`, `invalidAddress`,
  `invalidInvoice`, `invalidMnemonic`, `untrustedResponse`, `feeExceedsLimit`,
  `lightningSendIncomplete`.
- Bitcoin address decoding for P2PKH, P2SH, P2WPKH, P2WSH and P2TR with BIP-173/350 rules and
  network enforcement (static-deposit refunds previously rejected `bc1q` destinations).
- `claimDeposit(txID:vout:)` matches the transaction output that pays one of the wallet's unused
  deposit addresses; `vout` is now optional.

### Changed
- **Breaking:** `payLightningInvoice` takes a required `maxFeeSats`.
- **Breaking:** `exportAccountKey()` throws instead of crashing when the wallet uses a custom
  signer.
- `withdraw` amount semantics: exactly `amountSats` is withdrawn, fee deducted from it.
- `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and this `CHANGELOG.md`.
- `.env.example` and `Tests/SparkSDKTests/TestConfig.swift` for environment-driven test config.
- GitHub issue / pull request templates and Dependabot configuration.
- CI workflow (`.github/workflows/ci.yml`) running unit tests and lint on every PR.
- SwiftLint configuration (`.swiftlint.yml`).

### Changed
- `spark_frostFFI.xcframework` is now packaged as a **static-library** xcframework
  (`libspark_frostFFI.a` + headers) instead of a static archive wrapped in a `.framework`.
  It is linked into the consuming app rather than embedded under `Frameworks/`, which fixes
  App Store validation error ITMS-90208 ("does not support the minimum OS Version specified
  in the Info.plist") when an app sets a deployment target above the archive's baked-in
  minimum. No source or API changes — `import spark_frostFFI` is unchanged.
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

[Unreleased]: https://github.com/orklabs/spark-swift-sdk/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/orklabs/spark-swift-sdk/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/orklabs/spark-swift-sdk/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/orklabs/spark-swift-sdk/releases/tag/v0.1.0
