<h1 align="center">SparkSDK</h1>

<p align="center">
  A Swift SDK for the <a href="https://spark.money">Spark</a> protocol — self-custodial Bitcoin
  wallets powered by threshold FROST signing.
</p>

<p align="center">
  <a href="https://github.com/orklabs/spark-swift-sdk/actions/workflows/ci.yml"><img src="https://github.com/orklabs/spark-swift-sdk/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0-orange.svg" alt="Swift 6.0"></a>
  <a href="https://swiftpackageindex.com/orklabs/spark-swift-sdk"><img src="https://img.shields.io/badge/SPM-compatible-brightgreen.svg" alt="SPM"></a>
  <img src="https://img.shields.io/badge/platforms-iOS%2018%20%7C%20macOS%2015-lightgrey.svg" alt="Platforms">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
  <a href="https://github.com/orklabs/spark-swift-sdk/releases"><img src="https://img.shields.io/github/v/release/orklabs/spark-swift-sdk?include_prereleases&sort=semver" alt="Latest release"></a>
</p>

> ⚠️ **Self-custody warning.** SparkSDK manages cryptographic keys that control real Bitcoin.
> Mistakes — losing a mnemonic, leaking it, calling APIs without understanding the consequences
> — can result in permanent, irrecoverable loss of funds. Read [SECURITY.md](SECURITY.md) and
> the threat model before shipping this in production.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Creating a wallet](#creating-a-wallet)
  - [Deposits](#deposits)
  - [Lightning](#lightning)
  - [Spark transfers](#spark-transfers)
  - [Withdrawals](#withdrawals)
  - [Tokens](#tokens)
  - [Events & history](#events--history)
- [Networks](#networks)
- [Architecture](#architecture)
- [Error handling](#error-handling)
- [Concurrency](#concurrency)
- [Security model](#security-model)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Deposits** — one-time and reusable static taproot (P2TR) deposit addresses, with UTXO
  enumeration and claim flows.
- **Lightning** — create BOLT-11 invoices, pay invoices, fee estimation, LNURL-pay support.
- **Spark transfers** — send and receive between Spark wallets with sub-second finality.
- **Withdrawals** — cooperative exit to any on-chain Bitcoin address.
- **Tokens** — create, mint, transfer, and query Spark token balances.
- **Swaps** — denominate leaves via the SSP swap service.
- **Events** — async stream of incoming transfers and deposit confirmations.
- **History** — paginated query of inbound and outbound transfers.
- **Privacy controls** — toggle transaction visibility on the SSP.
- **Modern Swift** — `async/await`, `Sendable`, typed errors, Swift 6 strict concurrency.

## Requirements

| | Minimum |
|---|---|
| Swift  | 6.1  |
| Xcode  | 16.4 |
| iOS    | 18.0 |
| macOS  | 15.0 |

## Installation

### Swift Package Manager

In Xcode: `File ▸ Add Package Dependencies…` and paste:

```
https://github.com/orklabs/spark-swift-sdk.git
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/orklabs/spark-swift-sdk.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SparkSDK", package: "spark-swift-sdk"),
        ]
    ),
]
```

The SDK ships with a precompiled `spark_frostFFI.xcframework` for iOS device, iOS simulator
(arm64 + x86_64), and macOS (arm64 + x86_64). No additional setup is required.

CocoaPods and Carthage are not currently supported.

## Quick Start

```swift
import SparkSDK

// 1. Create a wallet from a BIP-39 mnemonic
let wallet = try SparkWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
await wallet.start()
defer { Task { await wallet.close() } }

// 2. Receive — generate a deposit address or a lightning invoice
let deposit = try await wallet.getStaticDepositAddress()
print("On-chain BTC ➜ \(deposit.address)")

let invoice = try await wallet.createLightningInvoice(amountSats: 1_000)
print("Lightning ➜ \(invoice.paymentRequest)")

// 3. Send — to another Spark wallet, on-chain, or over lightning
let balance = try await wallet.getBalance()
print("Available: \(balance.satsBalance.available) sats")

let transferId = try await wallet.send(
    receiverIdentityPublicKey: recipientPubKeyHex,
    amountSats: 500
)
```

## Usage

### Creating a wallet

```swift
// From a BIP-39 mnemonic (the most common case). The phrase is validated against the
// English wordlist and its checksum; a typo throws `SparkError.invalidMnemonic` instead of
// silently opening a different, empty wallet.
let wallet = try SparkWallet(mnemonic: "...", account: 0)

// Phrases known to be non-standard can skip validation.
let legacy = try SparkWallet(mnemonic: "...", validateMnemonic: false)

// From a raw 32-byte account key (advanced — bring-your-own-derivation)
let wallet = try SparkWallet(config: .init(network: .mainnet), accountKey: keyData)

// With a custom signer (e.g. hardware-backed, secure enclave)
let wallet = try SparkWallet(config: .init(network: .mainnet), signer: mySigner)

await wallet.start()
```

### Deposits

```swift
// Static (reusable) deposit address — preferred for most apps
let staticDeposit = try await wallet.getStaticDepositAddress()
let utxos = try await wallet.getUtxosForDepositAddress(address: staticDeposit.address)

// Once a UTXO confirms on-chain, claim it into your Spark balance
let transferId = try await wallet.claimStaticDeposit(
    transactionId: utxo.txid,
    outputIndex: utxo.vout
)

// One-time deposit addresses: the SDK locates the output that pays one of your unused
// deposit addresses (pass `vout:` to insist on a specific output).
try await wallet.claimDeposit(txID: txid)
```

### Lightning

```swift
// Receive
let invoice = try await wallet.createLightningInvoice(amountSats: 1_000, memo: "Coffee")

// Send
let fee = try await wallet.getLightningSendFeeEstimate(encodedInvoice: "lnbc...")
// `maxFeeSats` is required: the SSP's fee estimate is refused if it is above the cap.
let paymentId = try await wallet.payLightningInvoice(paymentRequest: "lnbc...", maxFeeSats: fee)

// Amountless invoices need an amount; invoices for another network are refused.
let zeroAmountPaymentId = try await wallet.payLightningInvoice(
    paymentRequest: "lnbc1...", maxFeeSats: 20, amountSats: 1_000
)

// Make a send resumable: on `SparkError.lightningSendIncomplete` call again with the
// same `transferId` and the coordinator resumes the existing transfer instead of locking
// a second set of leaves.
let transferId = UUID().uuidString
let resumable = try await wallet.payLightningInvoice(
    paymentRequest: "lnbc...", maxFeeSats: fee, transferId: transferId
)
```

### Spark transfers

```swift
// Pubkey form (33-byte compressed secp256k1 key)
let id = try await wallet.send(
    receiverIdentityPublicKey: Data(hexString: "02abcd...")!,
    amountSats: 500
)

// Spark address form (bech32m, must be for the wallet's network)
let id = try await wallet.send(
    receiverSparkAddress: "spark1...",
    amountSats: 500
)

// Receive side: claim any pending inbound transfers
try await wallet.claimAllPendingTransfers()
```

### Withdrawals

```swift
// Exactly `amountSats` leaves the wallet; the SSP's fee is deducted from it. Leaves are
// swapped to matching denominations first, so a partial withdrawal never overshoots.
let txid = try await wallet.withdraw(
    onChainAddress: "bc1q...",
    amountSats: 10_000,
    maxFeeSats: 500        // optional: refuse if the SSP quotes more (default: the quote itself)
)
```

Before anything is signed the SDK verifies the SSP's response: the exit transaction must
hash to the reported txid, pay `onChainAddress` at least `amountSats - fee`, and the connector
transaction must spend it. A response that fails throws `SparkError.untrustedResponse` and no
leaves are handed over. Destination addresses may be P2PKH, P2SH, P2WPKH, P2WSH or P2TR and
must belong to the wallet's network.

The exited leaves stay transfer-locked, and therefore in `satsBalance.owned`, until the exit
transaction confirms on-chain; `satsBalance.available` drops immediately. `satsBalance.frozen`
reports sats in leaves at the timelock floor, which the operators will neither move nor renew
and which only a unilateral exit can recover.

### Tokens

```swift
let token = try await wallet.createToken(
    tokenName: "Acme",
    tokenTicker: "ACME",
    decimals: 6,
    maxSupply: 1_000_000
)
try await wallet.mintTokens(tokenIdentifier: token.tokenIdentifier, tokenAmount: 1_000)
let balances = try await wallet.getTokenBalances()
```

### Events & history

```swift
// Stream of inbound transfer / deposit events
let events = wallet.subscribeToEvents()
for await event in events {
    print("event: \(event)")
}

// Paginated history
let page = try await wallet.getTransferHistory(direction: .all, limit: 20, cursor: nil)
```

## Networks

```swift
let mainnet = SparkConfig(network: .mainnet)
let regtest = SparkConfig(network: .regtest)

// Custom operators / SSP
let custom = SparkConfig(
    network: .mainnet,
    signingOperators: [...],
    sspURL: URL(string: "https://...")!
)
```

## Architecture

```
                  ┌─────────────────────────────────────┐
                  │              SparkWallet            │
                  └─────────────────────────────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
    ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
    │ Spark operators  │  │   SSP GraphQL    │  │ FROST signer     │
    │ (gRPC over HTTP/2)│  │  (HTTP/JSON)    │  │ (Rust, in-proc)  │
    └──────────────────┘  └──────────────────┘  └──────────────────┘
```

| File | Responsibility |
|---|---|
| `SparkWallet.swift`         | Public entry point, lifecycle, identity key |
| `SparkConfig.swift`         | Network / operator / SSP configuration |
| `SparkError.swift`          | Typed error enum |
| `SparkSigner.swift`         | Identity-key signing |
| `KeyDerivation.swift`       | BIP-39 / BIP-32 derivation |
| `Connection/`               | gRPC + GraphQL transport, auth |
| `Services/Balance*`         | Balance queries, leaf management |
| `Services/Transfer*`        | Spark-to-Spark transfers, claim, query |
| `Services/Lightning*`       | BOLT-11 invoice + payment |
| `Services/Deposit*`, `Address*` | One-time and static deposit addresses |
| `Services/Withdrawal*`      | Cooperative on-chain exits |
| `Services/Token*`           | Token create / mint / transfer / query |
| `Services/Swap*`            | SSP-mediated leaf denomination |
| `Services/Event*`           | Real-time event streaming |
| `Services/Settings*`        | Privacy mode, wallet settings |
| `Services/Frost*`, `KeyTweak*` | FROST round helpers |
| `Models/`                   | Public data types (`Sendable`) |
| `Proto/`, `Frost/`          | Generated bindings (do not edit) |

## Error handling

All public APIs throw `SparkError` — a typed enum with `LocalizedError` descriptions:

```swift
do {
    _ = try await wallet.payLightningInvoice(paymentRequest: "lnbc...")
} catch let error as SparkError {
    switch error {
    case .insufficientBalance(let need, let have):
        // show user-friendly message
    case .authenticationFailed(let reason):
        // re-auth flow
    case .feeExceedsLimit(let fee, let max):
        // the SSP quoted more than the caller allows — nothing was signed
    case .untrustedResponse(let reason):
        // an SSP / coordinator response failed client-side verification — nothing was signed
    case .lightningSendIncomplete(let transferId, let reason):
        // the coordinator holds the leaves; retry with the same transferId or reconcile via getTransferFromSsp
    case .invalidInvoice, .invalidAddress, .invalidMnemonic, .invalidArgument:
        // caller input problems
    case .grpcError, .graphqlError, .frostSigningFailed, .malformedTransaction:
        // transport / protocol failures
    default:
        // log and surface
    }
}
```

## Concurrency

- Every public type is `Sendable` and safe to share across actors.
- All I/O methods are `async throws`.
- The SDK requires no `MainActor` hops; call from any actor.
- Long-lived gRPC connections are managed inside a private actor; `start()` opens them and
  `close()` drains them.

## Security model

This is a self-custody wallet SDK. **Read [SECURITY.md](SECURITY.md) before shipping.**

Highlights:

- The host process is trusted — the SDK does not defend against a compromised app.
- The SSP and the coordinator are **not** trusted blindly: withdrawals verify the exit
  transaction before signing, inbound transfers verify the sender's signature before claiming,
  token commits verify the coordinator's final transaction, created invoices are checked against
  the requested hash and amount, and fees are capped by the caller.
- Mnemonic and account-key storage is the **app's responsibility**. Use Keychain on Apple
  platforms.
- The bundled `spark_frostFFI.xcframework` is a binary — see CONTRIBUTING.md for
  reproducibility / verification guidance.
- The SDK has not yet undergone a third-party audit.

To report a vulnerability, do **not** open a public issue. Use private vulnerability
reporting on this repo or email `gm@orklabs.com`.

## Testing

```bash
swift test                                         # unit tests only, when no .env is present
SPARK_TEST_DOTENV=/dev/null swift test             # force unit tests only, even with a .env
```

Integration tests connect to live Spark mainnet and require funded wallets configured via
`.env` (see [`.env.example`](.env.example)). They are not run in CI. **Note:** once a `.env`
with wallet mnemonics exists at the repo root, a plain `swift test` enables the integration
suites and moves real sats; point `SPARK_TEST_DOTENV` at an empty file to keep a run local.

```bash
cp .env.example .env
# edit .env with funded mnemonics — NEVER commit
swift test --filter IntegrationTests
```

## Contributing

PRs welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup, proto regeneration,
xcframework rebuild, coding standards, and the release process. Please read the
[Code of Conduct](CODE_OF_CONDUCT.md) before contributing.

## License

[MIT](LICENSE) © OrkLabs
