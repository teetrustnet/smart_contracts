# TrustNet Auction Business Logic v2 (Launchpad-ready)

Status: Draft for implementation (contract work follows after approval)

## 1. Goal

Upgrade the current multi-epoch blind Vickrey auction into a launchpad-ready flow for AI agents on BNB Chain, with:

- fair price discovery (sealed-bid, second-price style clearing),
- enforceable listing eligibility (ERC-8004 + TEE attestation),
- deterministic settlement rules,
- explicit risk and circuit-breaker guards.

---

## 2. Roles

- **Project / Agent Owner**: creates listing with agent identity and metadata.
- **Bidder**: submits commit/reveal bids.
- **Verifier**: validates TEE attestation result (off-chain verification + on-chain result write).
- **Treasury**: receives protocol fee / penalties.
- **Owner / Governance**: controls global parameters and emergency pause.

---

## 3. Listing Eligibility (before auction starts)

A listing is `ACTIVE` only if all checks pass:

1. **ERC-8004 identity check**
   - `agentId` exists
   - `agentId` owner (or agent wallet) matches listing creator
2. **Agent metadata check**
   - `agentURI` resolvable
   - required fields present (`services`, `attestation`, `execution endpoints`)
3. **TEE verification check**
   - `attestationHash` accepted by trusted verifier
   - verification timestamp within allowed freshness window
4. **Config sanity**
   - `tokensPerEpoch > 0`
   - `maxQuantityPerBid > 0`
   - durations and epoch count valid

If any check fails, listing remains `PENDING` and cannot open commit phase.

---

## 4. State Machine

Per listing:

- `PENDING` -> `ACTIVE` -> `ENDED` / `CANCELLED`

Per epoch:

- `COMMIT` -> `REVEAL` -> `FINALIZED`

Global override:

- `PAUSED` halts new commits/reveals/finalization writes (except owner rescue ops).

---

## 5. Auction Mechanics

## 5.1 Commit phase

Bidder submits:

- `commitment = keccak256(epochId, bidder, quantity, pricePerToken, salt)`
- collateral (BNB): `quantity * pricePerToken / 1e18`

Rules:

- one commitment per bidder per epoch (v2 keeps this simple)
- previous epoch must be finalized before next epoch commit
- bid floor enforced at reveal time (and may optionally be pre-checked in UI)

## 5.2 Reveal phase

Bidder reveals `(quantity, pricePerToken, salt)`.

Valid if:

- commitment matches,
- quantity in bounds,
- price >= floor,
- collateral covers max payment.

## 5.3 Finalization

Sort revealed bids by `pricePerToken` desc.
Allocate tokens until `tokensPerEpoch` exhausted.

Clearing price policy (v2 baseline):

- `clearing = max(floorPrice, highestLosingBidPrice)` when there is at least one losing revealed bid above floor,
- else `clearing = floorPrice`.

Winner payment:

- `payment = allocatedQty * clearing / 1e18`

Refund:

- winners: `collateral - payment`
- losers: full collateral
- non-reveal commits: `collateral - penalty`, penalty to treasury

Next floor:

- `nextFloor = max(1, clearing / 2)`

---

## 6. Economic Parameters

Global (governance controlled):

- `penaltyBps` (non-reveal penalty)
- `protocolFeeBps` (if enabled in later step)
- `maxEpochs`, `duration bounds`

Listing-level:

- `tokensPerEpoch`
- `maxQuantityPerBid`
- `initialFloorPrice`
- `totalEpochs`
- commit/reveal durations

---

## 7. Safety / Circuit Breakers

1. `pause()` / `unpause()`
2. stale verification lock:
   - listing auto-blocked if attestation freshness window exceeded
3. invalid listing rescind:
   - owner can set listing `CANCELLED` before first epoch commit opens
4. treasury withdrawal bounded by accounted accrual

---

## 8. Data Model (v2 additions)

In addition to existing epoch/bid state, add listing metadata fields:

- `listingId`
- `agentId`
- `agentOwner`
- `agentURI`
- `attestationHash`
- `attestationVerified`
- `attestationVerifiedAt`
- `listingStatus`

---

## 9. Events (v2 additions)

- `ListingCreated(listingId, creator, agentId)`
- `ListingActivated(listingId)`
- `ListingCancelled(listingId, reason)`
- `AttestationVerified(listingId, attestationHash, verifier)`
- Existing bid/epoch events remain.

---

## 10. Frontend/Backend Integration Contract

Before enabling "Bid Now":

- backend must return `listingStatus=ACTIVE`
- verify flags:
  - `erc8004Ok=true`
  - `attestationOk=true`
  - `auctionOpen=true`

If any false -> disable commit CTA with explicit reason.

---

## 11. Out of Scope (for this step)

- volume-inflation or wash-trading flows
- same-block buy/sell manipulation logic
- cross-listing routing optimizations

---

## 12. Acceptance Criteria (business logic sign-off)

- deterministic rules for commit/reveal/finalize/claim/refund,
- listing cannot enter ACTIVE without ERC-8004 + attestation checks,
- non-reveal penalty and treasury accounting unambiguous,
- next-floor rule and edge cases documented,
- ready to be translated into contract storage + functions.
