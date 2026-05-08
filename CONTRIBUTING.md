# Contributing to SparkSDK

Thanks for your interest in contributing! This document describes how to set up a
development environment, the workflow we follow, and the standards we expect.

By participating in this project you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md). For security issues, please follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Project Layout](#project-layout)
- [Building](#building)
- [Testing](#testing)
- [Regenerating Protobufs](#regenerating-protobufs)
- [Rebuilding the FROST xcframework](#rebuilding-the-frost-xcframework)
- [Coding Standards](#coding-standards)
- [Commit & PR Guidelines](#commit--pr-guidelines)
- [Release Process](#release-process)

---

## Quick Start

```bash
git clone https://github.com/p-i-g-g-y/spark-swift-sdk.git
cd spark-swift-sdk
cp .env.example .env       # fill in funded test mnemonics for integration tests
swift build
swift test                  # unit tests only — see below for integration
```

**Requirements**

- Xcode 16+ (Swift 6.0)
- macOS 15+ to run the macOS test suite
- For regenerating bindings: Rust toolchain, `protoc`, `swift-protobuf` plugin

## Project Layout

```
spark-swift-sdk/
├── Package.swift
├── Sources/SparkSDK/
│   ├── SparkWallet.swift         # Public entry point
│   ├── SparkConfig.swift         # Network configuration
│   ├── SparkError.swift          # Typed errors
│   ├── Connection/               # gRPC + GraphQL transport
│   ├── Services/                 # Feature modules (balance, transfer, lightning…)
│   ├── Models/                   # Public data types
│   ├── Proto/                    # Generated protobuf — DO NOT EDIT BY HAND
│   ├── Frost/                    # Generated UniFFI bindings — DO NOT EDIT BY HAND
│   └── GraphQL/                  # SSP GraphQL queries
├── Tests/SparkSDKTests/
│   ├── SparkSDKTests.swift       # Unit tests (no network)
│   ├── TokenTests.swift          # Unit tests for token helpers
│   ├── IntegrationTests.swift    # Hits live Spark mainnet — requires .env
│   └── TestConfig.swift          # Loads mnemonics from env / .env
├── Protos/                       # .proto source-of-truth
├── Frameworks/                   # spark_frostFFI.xcframework (binary)
└── scripts/
    └── build-xcframework.sh      # Rebuilds the FROST xcframework
```

## Building

```bash
swift build                       # debug
swift build -c release            # release
swift build --target SparkSDK     # explicit target
```

To verify SPM resolution from a clean state:

```bash
rm -rf .build .swiftpm
swift package resolve
swift build
```

## Testing

### Unit tests (no network, no funds)

```bash
swift test --filter SparkSDKTests
swift test --filter TokenTests
```

These cover key derivation, BIP-39 vectors, hex parsing, token validation, and
deterministic helpers. They use the canonical `abandon abandon … about` BIP-39
test vector and require no configuration.

### Integration tests (live network, real funds)

Integration tests connect to live Spark operators and submit real transactions.
**They require funded test wallets.** Configuration is loaded from environment
variables or a gitignored `.env` file:

```bash
cp .env.example .env
# edit .env with funded mnemonics
swift test --filter IntegrationTests
```

Required:
- `SPARK_TEST_WALLET_A_MNEMONIC` — funded with at least 500 sats
- `SPARK_TEST_WALLET_B_MNEMONIC` — does not need to be funded

See `Tests/SparkSDKTests/TestConfig.swift` for the full list of optional variables
(static deposit, external lightning, etc.).

> ⚠️ **Never commit `.env`.** It is listed in `.gitignore` for a reason.
> Mnemonics committed to git history are compromised forever — rotate immediately.

## Regenerating Protobufs

The files in `Sources/SparkSDK/Proto/` are generated. The `.proto` source-of-truth lives
in `Protos/` and is mirrored from [`buildonspark/spark`](https://github.com/buildonspark/spark).

To regenerate:

```bash
brew install swift-protobuf grpc-swift
protoc \
  --swift_out=Sources/SparkSDK/Proto \
  --grpc-swift_out=Sources/SparkSDK/Proto \
  --proto_path=Protos \
  Protos/*.proto
```

If you change a `.proto` and submit it for review, please also commit the regenerated
`.swift` files in the same PR.

## Rebuilding the FROST xcframework

The bundled `Frameworks/spark_frostFFI.xcframework` is built from the `spark-frost` Rust
crate. To rebuild:

```bash
./scripts/build-xcframework.sh
```

Prerequisites: Rust toolchain with iOS / macOS targets installed, `cargo`, and access to the
`buildonspark/spark` repository.

The build script clones the upstream repo, compiles for five Rust targets (iOS arm64, iOS
sim arm64 + x86_64, macOS arm64 + x86_64), and assembles them into a single xcframework with
`lipo`.

Replacing the binary in `Frameworks/` is a security-sensitive operation. PRs that update the
xcframework must:

1. Be reproducible from a published `spark-frost` commit hash (record it in the PR description).
2. Include a SHA-256 hash of the resulting xcframework in the PR description.
3. Be reviewed by a maintainer with cryptography sign-off.

## Coding Standards

- **Swift 6 strict concurrency** — every public type should be `Sendable`. Errors should be
  typed via `SparkError`.
- **No force unwraps in new code.** Prefer `guard let`, throwing initialisers, or proper error
  propagation. Existing `!` usages are being phased out.
- **No `print` statements** outside of integration tests. Use `os.Logger` or expose the
  diagnostic via the public API.
- **Public API gets doc comments** (`///`) with `- Parameter:`, `- Throws:`, and `- Returns:`
  sections. DocC will render these.
- **Lint** with `swiftlint` before pushing (config in `.swiftlint.yml`):

  ```bash
  brew install swiftlint
  swiftlint
  ```

- **Format** with `swift-format` (Apple's official formatter):

  ```bash
  swift format -i -r Sources Tests
  ```

CI enforces both lint and format. PRs that fail will not be merged.

## Commit & PR Guidelines

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, `chore:`. Breaking changes use `feat!:` or `BREAKING CHANGE:` footer.
- Keep PRs focused. Bundle protobuf regeneration with the `.proto` change that motivated it.
- Each PR should:
  - Pass CI (build + unit tests + lint).
  - Add or update tests for behaviour changes.
  - Update `CHANGELOG.md` under the `## [Unreleased]` heading.
  - Update relevant DocC / README sections.

## Release Process

1. Update `CHANGELOG.md` — move `## [Unreleased]` items under a new `## [x.y.z]` heading.
2. Update the version constant if applicable.
3. Tag the release: `git tag -s vX.Y.Z -m "Release vX.Y.Z"` (signed tags preferred).
4. Push tag: `git push origin vX.Y.Z`. The `release.yml` workflow will create the GitHub
   Release with auto-generated notes.
5. Announce in the relevant channels.

---

Thanks again for contributing!
