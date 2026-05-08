# Security Policy

SparkSDK handles cryptographic keys that control real Bitcoin. We take security seriously
and appreciate responsible disclosure from the community.

## Reporting a Vulnerability

**Do not file public GitHub issues for security vulnerabilities.**

Please report security issues privately by either:

1. **Email** — `gm@orklabs.com`
2. **GitHub Security Advisories** — use the
   [private vulnerability reporting](https://github.com/p-i-g-g-y/spark-swift-sdk/security/advisories/new)
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
  not implement certificate pinning by default.
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
- **No telemetry**. The SDK makes no network calls beyond Spark operators and the configured
  SSP endpoint.

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
