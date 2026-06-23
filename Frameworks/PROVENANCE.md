# spark_frostFFI.xcframework — Provenance

This file records the origin and integrity of the binary `spark_frostFFI.xcframework`
shipped in this directory. It exists so consumers of SparkSDK can verify the binary
matches its open-source Rust source.

> ⚠️ Binary frameworks are inherently harder to audit than source. If you require a
> from-source build, run [`scripts/build-xcframework.sh`](../scripts/build-xcframework.sh)
> against the recorded upstream commit and verify the resulting checksums match.

## Source

| | |
|---|---|
| Upstream repository | <https://github.com/buildonspark/spark> |
| Crate path          | `signer/spark-frost-uniffi/` |
| Bound API           | UniFFI bindings for the `spark-frost` FROST signing implementation |
| Upstream commit     | _**TODO** — record the exact `buildonspark/spark` commit SHA used to build the bundled binary_ |
| Build date          | _**TODO** — fill in_ |
| Builder             | _**TODO** — name / build host_ |

## Targets

The bundled xcframework contains three slices:

| Slice | Triple(s) | Min OS |
|---|---|---|
| `ios-arm64`                     | `aarch64-apple-ios`                                     | iOS 18.0 |
| `ios-arm64_x86_64-simulator`    | `aarch64-apple-ios-sim`, `x86_64-apple-ios`             | iOS 18.0 simulator |
| `macos-arm64_x86_64`            | `aarch64-apple-darwin`, `x86_64-apple-darwin`           | macOS 15.0 |

Each slice is a **static library** (`libspark_frostFFI.a`) plus a `Headers/`
directory (the UniFFI-generated C header and a module map). It is packaged as a
static-library xcframework — *not* a `.framework` wrapper — so consumers link it
into their app binary rather than embedding it under `Frameworks/`. Embedding a
static archive wrapped as a framework triggers App Store validation error
ITMS-90208 once the app's deployment target is raised above the archive's frozen
`MinimumOSVersion`; a linked static library has no such constraint.

## Reproducible build

```bash
# 1. Pin upstream to the recorded commit
git clone https://github.com/buildonspark/spark /tmp/spark
git -C /tmp/spark checkout <UPSTREAM_COMMIT_SHA>

# 2. Run the bundled build script — it will use /tmp/spark and assemble the xcframework
./scripts/build-xcframework.sh 18.0

# 3. Compare checksums (should match the table below)
shasum -a 256 \
  Frameworks/spark_frostFFI.xcframework/ios-arm64/libspark_frostFFI.a \
  Frameworks/spark_frostFFI.xcframework/ios-arm64_x86_64-simulator/libspark_frostFFI.a \
  Frameworks/spark_frostFFI.xcframework/macos-arm64_x86_64/libspark_frostFFI.a
```

## Checksums (SHA-256)

These are the checksums of the binary slices currently committed to this repository.
They are recomputed and verified by the `release.yml` workflow on every tagged release.

| Path | SHA-256 |
|---|---|
| `Info.plist` | `fef1ec1aa0b7464a97a909256a9ef5babe65ba83ff84a573cd7f77a689f2d51a` |
| `ios-arm64/libspark_frostFFI.a` | `4cbe90ae7c4c68c881a4eb88e070e91232c55072ea30e65a55b21d57404b38a0` |
| `ios-arm64_x86_64-simulator/libspark_frostFFI.a` | `a8743b1723f3a5c8fad21fb5236759d7ae9862b3999a0f191d71b516b8391648` |
| `macos-arm64_x86_64/libspark_frostFFI.a` | `2f5a61513fd158214043d2223eee68af88e7409c7392dbf365eeeade633686df` |

To regenerate this table:

```bash
find Frameworks/spark_frostFFI.xcframework -type f \
    \( -name 'libspark_frostFFI.a' -o -name 'Info.plist' \) \
    | sort | xargs shasum -a 256
```

## Updating this file

When updating `spark_frostFFI.xcframework`, the PR MUST:

1. Fill in the `Upstream commit`, `Build date`, and `Builder` fields above.
2. Regenerate the checksum table.
3. Be reviewed by a maintainer with cryptography sign-off (see
   [SECURITY.md](../SECURITY.md) and [CONTRIBUTING.md](../CONTRIBUTING.md)).
