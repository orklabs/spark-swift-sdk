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

## Reproducible build

```bash
# 1. Pin upstream to the recorded commit
git clone https://github.com/buildonspark/spark /tmp/spark
git -C /tmp/spark checkout <UPSTREAM_COMMIT_SHA>

# 2. Run the bundled build script — it will use /tmp/spark and assemble the xcframework
./scripts/build-xcframework.sh 18.0

# 3. Compare checksums (should match the table below)
shasum -a 256 \
  Frameworks/spark_frostFFI.xcframework/ios-arm64/spark_frostFFI.framework/spark_frostFFI \
  Frameworks/spark_frostFFI.xcframework/ios-arm64_x86_64-simulator/spark_frostFFI.framework/spark_frostFFI \
  Frameworks/spark_frostFFI.xcframework/macos-arm64_x86_64/spark_frostFFI.framework/spark_frostFFI
```

## Checksums (SHA-256)

These are the checksums of the binary slices currently committed to this repository.
They are recomputed and verified by the `release.yml` workflow on every tagged release.

| Path | SHA-256 |
|---|---|
| `Info.plist` | `59125729565d9c90813027cc6dd5b4e2d0e6482a0e01e55f0daea9e128aa5fa9` |
| `ios-arm64/spark_frostFFI.framework/Info.plist` | `7cd5ead5c2def54353f6b64dd0e16fd95eb0bbf279ff7c097a46bccd4a7a183d` |
| `ios-arm64/spark_frostFFI.framework/spark_frostFFI` | `4cbe90ae7c4c68c881a4eb88e070e91232c55072ea30e65a55b21d57404b38a0` |
| `ios-arm64_x86_64-simulator/spark_frostFFI.framework/Info.plist` | `7cd5ead5c2def54353f6b64dd0e16fd95eb0bbf279ff7c097a46bccd4a7a183d` |
| `ios-arm64_x86_64-simulator/spark_frostFFI.framework/spark_frostFFI` | `a8743b1723f3a5c8fad21fb5236759d7ae9862b3999a0f191d71b516b8391648` |
| `macos-arm64_x86_64/spark_frostFFI.framework/Info.plist` | `cff7c2e0ebddaeed427d81d226c0916b06ada033c7154640b862ab34ccd29e71` |
| `macos-arm64_x86_64/spark_frostFFI.framework/spark_frostFFI` | `2f5a61513fd158214043d2223eee68af88e7409c7392dbf365eeeade633686df` |

To regenerate this table:

```bash
find Frameworks/spark_frostFFI.xcframework -type f \
    \( -name 'spark_frostFFI' -o -name 'Info.plist' \) \
    | sort | xargs shasum -a 256
```

## Updating this file

When updating `spark_frostFFI.xcframework`, the PR MUST:

1. Fill in the `Upstream commit`, `Build date`, and `Builder` fields above.
2. Regenerate the checksum table.
3. Be reviewed by a maintainer with cryptography sign-off (see
   [SECURITY.md](../SECURITY.md) and [CONTRIBUTING.md](../CONTRIBUTING.md)).
