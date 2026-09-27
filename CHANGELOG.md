# Changelog

All notable changes to SparkSDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the SDK is in `0.x`, the public API is considered unstable and minor releases may
contain breaking changes. Each breaking change will be documented under "Changed" with a
migration note.

---

## [Unreleased]

### Security
- Deposit addresses are verified before they are returned, as the reference SDK does. The SDK
  handed out whatever address and verifying key the coordinator sent, so a coordinator — or
  anyone impersonating it — could substitute an address it alone controls, and a static address
  is reused for every deposit. `getDepositAddress` and `getStaticDepositAddress` now check the
  operators' proof of possession, every operator's signature over the address (the
  coordinator's too for static addresses) against the configured keys, and that the address pays
  the verifying key, and throw `SparkError.untrustedResponse` otherwise.
- `createLightningInvoice` refuses an SSP-created invoice that carries a Spark fallback — a
  Spark identity in the sentinel route hint (`f42400f424000001`) or a Spark invoice in a
  version-31 fallback field — which the wallet never asks for. A malicious SSP could otherwise
  name its own identity there, and payers that prefer paying over Spark would pay the SSP instead
  of this wallet. `Bolt11Invoice` decodes both forms as the reference SDK does.

### Added
- `claimPendingTransfers()`: claims every pending inbound transfer and returns the claimed
  transfer ids plus the transfers that could not be claimed, with their errors.
- `SparkLeaf.isFrozen`, and `unrenewedSats` on `WithdrawAllQuote` and `WithdrawAllResult`:
  renewable sats a drain leaves behind because the operators did not renew them.

### Changed
- `subscribeToEvents()` streams until the caller stops iterating or the wallet is closed: it
  reconnects by itself and reports `SparkEvent.reconnecting(attempt:retryIn:reason:)` before
  each wait — a new case that exhaustive `switch`es over `SparkEvent` must handle — and it claims
  incoming payments itself (see Fixed). It throws only when the wallet is already closed.
- `SatsBalance.owned` and `locked` follow the reference SDK: available + frozen + leaves an
  in-flight operation still holds for the wallet (outgoing transfers, Lightning payments and
  cooperative exits before the operators apply the sender's key tweak, swaps the wallet started
  and their counter-transfers until claimed). Sent sats leave `owned` as soon as the transfer is
  committed instead of when the receiver claims it, and `getBalance`/`getLeaves` query only
  AVAILABLE nodes.

### Fixed
- `refundStaticDeposit` and `refundAndBroadcastStaticDeposit` work. Three defects each stopped
  every refund: the unsigned spend transaction was serialised with the segwit marker and an empty
  witness, which the signing library refuses to parse ("witness flag set but no witnesses
  present") and the operators would not have matched against the transaction they rebuild; the
  deposit's txid went to the operators in internal byte order, while they look deposits up in
  display order; and the refund statement ended with the sighash as 64 hex characters instead of
  its 32 raw bytes, which the operators verify. The refund now matches the reference SDK and the
  operators' checks byte for byte, takes the txid in any case, and checks that the block
  explorer's transaction hashes to it.
- The event stream no longer dies silently, as in the reference SDK's background stream. Any
  error, or the operator ending the subscription (a network change, a deploy), finished the
  `AsyncStream` as if it were a normal end, it never reconnected, and payments that arrived in
  the meantime waited until something else claimed them. It now resubscribes forever — 1 s
  doubling to 15 s between attempts — claims the wallet's pending transfers on every connection
  and reports those payments as `.transferReceived`, and claims each payment that arrives while
  connected before reporting it. `close()` stops the wallet's streams; before, a live stream
  kept the old connection open.
- The event stream no longer reports the counter-transfer of the wallet's own swap as a received
  payment, as the reference SDK does. Every send that needed change, withdrawal, Lightning
  payment and consolidation showed up as incoming money, and an app that claims on
  `.transferReceived` raced the swap's own claim. Self-transfers are not reported as received
  either, and a deposit is reported once its leaf is available. `.transferSent` is documented as
  what it is: every status change of an outgoing transfer.
- A transfer or leaf value of 2^63 sats or more from an operator — or an output value that large
  from the block explorer — no longer crashes the app. `Int64(value)` trapped on it in the event
  stream, transfer history, send results, balances, recovery and static deposits, so a hostile or
  corrupt coordinator could crash the app every time the event stream started. Reported amounts
  are now capped at the bitcoin supply, which also keeps sums of them from overflowing.
- `send(receiverSparkAddress:)` and `transferTokens` refuse Spark invoices with
  `SparkError.invalidAddress`, as the reference SDK does. A Spark invoice is a Spark address
  whose payload also carries an amount, expiry, sender restriction and the payee's signature; the
  SDK read only the identity key at the front, so a pasted invoice paid the payee's key whatever
  it said, without linking the transfer to it — the payee saw it unpaid and the payer might pay
  again. Addresses are now decoded whole, as the reference SDK decodes them, the identity key must
  be a valid curve point, and `transferTokens` checks the receiver before fetching outputs.
  Paying Spark invoices (`fulfillSparkInvoice`) is not supported yet.
- `payLightningInvoice` offers the SSP its fee estimate as is, as the reference SDK does. A 1-sat
  floor turned an estimate of 0 into a 1-sat fee and refused the README's
  `maxFeeSats: estimate` pattern with `feeExceedsLimit`.
- `payLightningInvoice` sends on the invoice it validated. An invoice pasted with surrounding
  whitespace or in upper case passed the SDK's checks, but the raw string went to the SSP, which
  refused it ("not a valid Lightning Network invoice"). The trimmed, lower-case form now goes to
  the SSP and into the preimage swap, as the reference SDK lower-cases the invoice first; a
  mixed-case string is still refused.
- BOLT-11 invoices without a payment secret (`s` field) are refused, as BOLT-11 readers must
  and the reference SDK does. They were accepted for payment, and an SSP-created invoice without
  one passed the receive checks.
- A Lightning send whose preimage swap fails without a clear refusal — a connection lost after
  the request went out, a deadline, a cancelled task, an internal error — throws
  `lightningSendIncomplete` with the transfer id. The coordinator may have committed such a swap
  and locked the leaves, and the error carried no id to resume with, so they stayed locked until
  the transfer expired. A swap the operators refused before committing (invalid argument,
  unavailable leaf, lock conflict, …) still throws its own error.
- Resuming a Lightning send no longer selects leaves again. A retry with the `transferId` from
  `lightningSendIncomplete` re-ran leaf selection before the coordinator's idempotent swap, but
  the first attempt's leaves were locked by then, so the retry failed with `insufficientBalance`
  whenever the rest of the wallet could not cover the payment a second time, or swapped for
  change it never used. The SDK now asks the coordinator for the send it holds under that id
  (`query_htlc`), checks that it is this wallet's HTLC to the SSP for this invoice, neither
  returned nor expired, with at most `maxFeeSats` beyond the amount, and has the SSP pay from
  it. The SSP answers a repeated request for a transfer with the request it already has, so a
  send that went through returns its request id instead of paying twice.
- A Lightning send's preimage swap always carries an idempotency key — the caller's
  `idempotencyKey`, else the transfer id — as the reference SDK's does. Without either argument
  it carried none, so when the coordinator committed the swap but its answer was lost, the
  transport's retry was refused as a second transfer and the caller never learnt the transfer id;
  and a first attempt without a key that ended in `lightningSendIncomplete` could not be resumed
  with the reported transfer id. Either way the leaves stayed locked until the transfer expired.
- SSP fee amounts are read in the unit the SSP reports. The Lightning fee estimate was always
  divided by 1000 as if it were in millisatoshi, and the cooperative-exit fees were taken as
  sats; an estimate reported in another unit would have been misread, capped against the wrong
  number and, for Lightning, underpaid after the leaves were locked. `original_unit` is now read
  (SATOSHI, MILLISATOSHI rounded up) and any other unit is refused, as the reference SDK does
  for the Lightning estimate.
- Lightning preimage shares go to the operator that validates them. Share `i` went to the `i`-th
  configured operator, but each operator validates the share at its own index (encoded in its
  identifier), so a configuration listing operators in another order made every invoice creation
  fail. Shares are now matched by index, as the reference SDK does.
- Lightning receives no longer sign the preimage-share request with the identity key. The
  current protocol reserves `user_signature` on `store_preimage_share_v2` and the operators never
  read it; the reference SDK dropped it in 0.6.5.
- Lightning sends no longer sign plain refunds over to the SSP. The SDK still filled the legacy
  `transfer` field of `initiate_preimage_swap_v3`, with an extra signing round and the user's
  signature shares on non-HTLC refunds paying the SSP. The operators build the swap from
  `transfer_request` alone and the current protocol reserves the field; the reference SDK stopped
  sending it in 0.9.0. A Lightning send now makes one signing round fewer.
- Amountless Lightning invoices can be paid. The SSP's `request_lightning_send` needs
  `amount_sats` for an invoice without an amount (and only then), and the SDK never sent it,
  although it had already quoted the fee for the caller's amount and locked the leaves with the
  operators — the leaves then stayed locked until the transfer expired.
- Legacy deposit-root leaves whose node transaction has a final (timelock-disabled) sequence can
  be renewed. The operators renew them like zero-timelock nodes; the SDK read the final sequence
  as timelock 65535, went looking for a parent the root does not have, and failed.
- Claimed leaves and swap outputs in the renewal range are renewed, as the reference SDK does.
  A transfer from a leaf at 200 delivers it at 100; the claim now renews such leaves right away
  (best effort). A send or withdrawal that swapped for change filtered the SSP's new leaves by
  spendability and threw when they arrived at 100…199, although the swap had already gone
  through; it now renews them before selecting, and consolidation renews between rounds.
- Leaves hanging off any output but the first of their parent can be renewed. Refund and node
  renewals spent parent output 0 and paid that output's script, while the operators rebuild the
  renewal from the parent's output at the leaf's `vout`, paying P2TR of the leaf's verifying key,
  and compare byte for byte — so such a leaf could never be renewed and, once its timelock ran
  down, looked frozen. (The reference SDK has the same bug.)
- `SatsBalance.incoming` no longer counts a swap's counter-transfer, which `locked` already
  counts, so every swap (a send that needs change, a withdrawal, a Lightning payment,
  consolidation) briefly reported the same sats twice. Incoming now sums the leaves of every page
  of pending inbound transfers, as the reference SDK does, instead of the first page's transfer
  totals, and leaves a self-transfer's leaves to `locked`.
- `SatsBalance.owned` and `locked` no longer grow permanently with every node-level renewal. A
  node or zero-timelock renewal leaves a SPLIT_LOCKED split node that keeps the owner key and the
  leaf's full value (`renew_leaf_handler.go`), and the balance counted every SPLIT_LOCKED node
  as owned, so `locked` (and `WithdrawAllQuote.lockedSats`) reported sats that never settle.
- `SatsBalance.frozen` counts only leaves the operators will not renew: a refund timelock below
  100. A leaf at exactly 100 — what a transfer from a leaf at 200 routinely leaves the receiver
  — was reported frozen, although the coordinator renews refund timelocks from 100 up; frozen
  figures (analytics, debug screens, the `withdrawAll` quote) therefore overstated what only a
  unilateral exit can recover. Leaves at 100–199 now count as available, as in the reference
  SDK, because every spend path renews them first; any the operators decline to renew during a
  drain are reported as `unrenewedSats` instead of vanishing from the quote.
- Leaves whose refund timelock is not a multiple of 100 can be spent again, and leaves at 101–199
  blocks are no longer selected without a renewal. The next refund timelock was the current one
  minus 100; the operators require the current one rounded down to the 100-block interval, minus
  100 (a leaf at 740 needs 600, not 640), and refuse any leaf whose rounded timelock is 100 or
  less. Such leaves counted as spendable but made every send, swap and cooperative exit that used
  them fail — one of them failed a whole `withdrawAll`. `SparkLeaf.isSpendable` now means a
  rounded refund timelock above 100 (at least 200). Lightning HTLC refunds keep their unrounded
  offsets, which is how the operators rebuild them.
- Leaves on a zero-timelock node can be sent and claimed again. Send and claim built a direct
  refund whenever the node carried a direct transaction, and the operators reject a direct refund
  for a zero node ("zero nodes must not have a direct refund tx") — the shape zero-timelock
  renewal leaves behind, a timelock-0 node transaction together with a direct one. Such a leaf
  could not be sent, and an inbound transfer carrying one could never be claimed. Send, claim and
  cooperative exit now share one refund builder with the reference SDK's `isZeroNode` rule
  (Lightning HTLC refunds keep their own rule, which the operators check separately).
- One pending transfer the SDK cannot claim no longer blocks every other incoming payment.
  `claimAllPendingTransfers` stopped at the first failure and read a single page, and the
  operators store a transfer's per-leaf sender signatures without verifying them, so anyone could
  plant a transfer that the SDK (rightly) refuses and stall all claims behind it. Claims now
  follow the reference SDK's claim pass: pages of 25 until the pending set is drained, only
  claimable statuses, failures recorded and skipped, and claims serialised per wallet so a claim
  pass, a swap's counter-transfer claim and `withdrawAll` no longer race each other. A transfer
  the operators already recorded as claimed by this wallet (ALREADY_EXISTS) counts as claimed.
  `claimAllPendingTransfers` still returns the number claimed.
- An operator rejecting a session token no longer crashes the app. The auth interceptor replayed
  the call on the same HTTP/2 stream, which swift-nio treats as a fatal error ("allows only a
  single AsyncIterator to be created"). It fired whenever the event subscription, or any call
  the operator refused without response headers, was answered UNAUTHENTICATED — for example on
  a device whose clock runs more than a minute behind. The interceptor now drops the rejected
  token and the transport's retry policy re-issues the call on a new stream with a fresh one,
  as the official SDK's auth middleware does.

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
