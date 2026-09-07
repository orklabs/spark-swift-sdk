# Security Policy

SparkSDK handles cryptographic keys that control real Bitcoin. We take security seriously
and appreciate responsible disclosure from the community.

## Reporting a Vulnerability

**Do not file public GitHub issues for security vulnerabilities.**

Please report security issues privately by either:

1. **Email** — `gm@orklabs.com`
2. **GitHub Security Advisories** — use the
   [private vulnerability reporting](https://github.com/orklabs/spark-swift-sdk/security/advisories/new)
   form on this repository.

Include as much of the following as possible:

- A description of the vulnerability and its impact.
- A minimal proof-of-concept (code, transactions, network captures).
- The affected version(s) / commit(s).
- Your name and affiliation, if you'd like credit in the advisory.

## Response Targets

| Phase | Target |
|---|---|
| Acknowledgement | Within 3 business days |
| Initial triage  | Within 7 business days |
| Fix or mitigation | Severity-dependent; critical issues prioritised within 30 days |
| Public disclosure | Coordinated with reporter after a fix ships |

We will keep you updated through the process and credit you in the published advisory unless
you prefer otherwise.

## Scope

In scope:

- The `SparkSDK` Swift module and its public API.
- The bundled `spark_frostFFI.xcframework` binary in this repository.
- The build script under `scripts/`.

Out of scope:

- Vulnerabilities in upstream dependencies (`grpc-swift`, `swift-protobuf`, `secp256k1.swift`,
  the `spark-frost` Rust crate). Please report those upstream; we'll bump pins as soon as a fix
  is released.
- Vulnerabilities in the Spark protocol itself or in Spark Service Provider (SSP) infrastructure
  — report those to the [Spark project](https://github.com/buildonspark/spark) directly.
- Issues that require physical device access, a compromised host, or a malicious dependency
  injected by the user.
- Findings against unsupported versions (anything older than the latest minor release).

## Threat Model

SparkSDK assumes:

- The host process is trusted. The SDK does not defend against a compromised application
  reading memory, intercepting syscalls, or modifying binaries at runtime.
- The user is responsible for **secure storage** of mnemonics and account keys. The SDK does
  not provide Keychain integration, encrypted-at-rest storage, or hardware-key isolation.
  Apps embedding the SDK MUST take care of these.
- Network transport is gRPC over TLS to Spark operators and HTTPS to the SSP. The SDK does
  not implement certificate pinning by default; the response verification described below is
  what limits the damage an impersonated SSP or coordinator can do.
- The cryptography is provided by `secp256k1.swift` (ECDSA / Schnorr) and the
  `spark-frost` Rust crate (FROST threshold signing). Bugs in those libraries are out of
  scope and tracked upstream.

## Cryptographic Material Handling

- **Mnemonics** are accepted as `String` and converted to seed material via PBKDF2-SHA512.
  They are not zeroed from memory after use; the `String` lifetime is governed by Swift's
  ARC. Apps that need explicit zeroization should prefer the `init(config:accountKey:)`
  initialiser with a short-lived `Data` buffer they control.
- **Account keys** never leave the device. The SDK derives identity / signing keys locally
  via BIP-32 and uses them for FROST signing rounds with operators.
- **No telemetry**. The SDK makes no network calls beyond Spark operators, the configured SSP
  endpoint, and a block explorer (`mempool.space` on mainnet, a local electrs on regtest) used
  to fetch raw transactions for one-time deposit claims and to broadcast static-deposit
  refunds. Transaction ids sent to the explorer are visible to it.

## What the SDK Verifies

Responses from the Spark Service Provider and the coordinator are checked on the device before
any key material is used:

- **Withdrawals** — the SSP's exit transaction must hash to the reported txid and pay the
  requested address at least `amount - fee`; the connector transaction must spend it; the fee
  is bounded by the caller's `maxFeeSats` or the SSP's own quote. Leaves are swapped to the
  exact amount first so no more than requested leaves the wallet.
- **Lightning sends** — the invoice must decode (BOLT-11 checksum, network, overflow-checked
  amount) and belong to the wallet's network; the SSP fee estimate must be within
  `maxFeeSats`.
- **Lightning receives** — the invoice the SSP returns must carry our payment hash, amount and
  network before preimage shares are stored.
- **Inbound transfers** — every leaf's sender signature over
  `sha256(leafId || transferId || secretCipher)` is verified against the sender identity key
  before any secret is decrypted or refund signed.
- **Token transactions** — the coordinator's final transaction must equal the submitted partial
  transaction apart from server-set fields, with the expected withdraw bond and locktime.
- **Operators** — secret shares are only ever encrypted to operator identity keys from the local
  configuration; a coordinator operator list that does not match the configuration is refused.
- **Mnemonics** — validated against the BIP-39 English wordlist and checksum by default.

Anything that fails these checks throws (`SparkError.untrustedResponse`,
`.feeExceedsLimit`, `.invalidInvoice`, ...) before a signature is produced.

## Audit Status

This SDK has **not** undergone a formal third-party security audit yet. Use at your own risk
in production. We will publish audit reports here as they become available.

## Supported Versions

We aim to ship security fixes for the latest minor release. While the SDK is in `0.x`, only
the most recent published version is officially supported.

| Version | Supported |
|---|---|
| `0.x` (latest) | Yes |
| Older `0.x`    | Best-effort |
| `pre-release`  | No |
