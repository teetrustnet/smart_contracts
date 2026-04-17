# MultiEpochAuctionApplicationMVP — 3-Layer Security Audit (2026-04-17)

## Scope

- Contract: `contracts/MultiEpochAuctionApplicationMVP.sol`
- Focus: launch lifecycle, bid settlement, treasury/refund safety, token distribution safety, admin controls.

## Layer 1 — System / Governance / Launch Controls

### Findings addressed

1. **Settlement lock after close**
   - Fix: added app-specific settlement entrypoints:
     - `finalizeEpoch(applicationId, epochId, maxParticipants)`
     - `claimTokens(applicationId, epochIds)`
     - `withdrawRefund(applicationId, epochId)`
   - Impact: users can still settle after `status=Closed`.

2. **Unsafe unsold-token recovery window**
   - Fix: `recoverUnsoldTokens` now requires:
     - `status == Closed`
     - all epochs finalized
     - requested amount <= provable unsold cap
   - Added tracking: `recoveredUnsoldWholeTokens`.

3. **Treasury destination ambiguity**
   - Fix: `withdrawTreasury(to, amount)` now enforces `to == treasury`.

4. **Launch time sanity**
   - Fix: `launchAuctionApplication` now rejects past `startTime`.

## Layer 2 — Economic / Auction Mechanics

### Findings addressed

1. **Finalize DoS by unbounded participant loop**
   - Fix: batch finalization with cursor:
     - `finalizeCursor[appId][epochId]`
     - chunk size controlled by `maxParticipants`
     - default legacy finalize uses `DEFAULT_FINALIZE_BATCH`.

2. **Refund accounting visibility/safety**
   - Fix: added global liability tracker:
     - `totalRefundLiability`
   - Updated on materialization/finalization/withdraw paths.

3. **Treasury vs refund segregation**
   - Fix: `rescueExcessETH` introduced to only rescue ETH above
     `treasuryAccrued + totalRefundLiability`.

## Layer 3 — Code / Integration Safety

### Findings addressed

1. **Token decimals hardcode risk (1e18 assumption)**
   - Fix: constructor auto-detects token `decimals()` (fallback 1e18 when unavailable) and stores `tokenUnitScale`.
   - Claim/recovery operations now use `tokenUnitScale`.

2. **Post-close read path for auditors/ops**
   - Fix: added `getUserBidFor(applicationId, user, epochId)` for explicit app inspection.

## Residual risks / recommendations

1. **Owner trust model remains strong** (expected in MVP):
   - owner can pause/unpause and control app lifecycle.
   - Recommend multisig + timelock for production.

2. **Token contract risk remains external**:
   - If sale token is upgradeable/mintable by privileged roles, this system inherits that risk.
   - Require separate token audit + mint role hardening.

3. **Operational requirement**:
   - ensure auction inventory is funded before claims.

## Validation

- `npm run compile` ✅
- `npm run test` ✅
- `npm run smoke:local` ✅
