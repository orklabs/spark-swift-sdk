<!--
Thanks for your contribution! Please fill in the sections below.
For security-sensitive changes, see SECURITY.md before opening a public PR.
-->

## Summary

<!-- One or two sentences describing what this PR does and why. -->

## Type of change

- [ ] Bug fix (non-breaking)
- [ ] New feature (non-breaking)
- [ ] Breaking change (API removal, signature change, behaviour change)
- [ ] Documentation only
- [ ] Build / CI / tooling
- [ ] Refactor (no functional change)

## Linked issues

<!-- Closes #123, Refs #456 -->

## Testing

- [ ] Added or updated unit tests
- [ ] Verified locally with `swift test --filter SparkSDKTests`
- [ ] Verified integration tests (if applicable) with funded `.env` wallets
- [ ] Updated `CHANGELOG.md` under `## [Unreleased]`

## API surface

- [ ] No public API changed
- [ ] Public API changed — described below

<!-- If public API changed, list the diff and migration notes. -->

## Security checklist

- [ ] No mnemonics, private keys, or other secrets are added in code, tests, or fixtures
- [ ] No new force unwraps (`!`) introduced in non-generated code
- [ ] If updating `Frameworks/spark_frostFFI.xcframework`: source commit + SHA-256 of the binary recorded below
- [ ] If touching cryptographic code: rationale and review notes below

<!-- xcframework provenance:
spark-frost commit: ...
xcframework SHA-256: ...
-->
