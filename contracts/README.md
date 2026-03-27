# Auction Solidity Contracts

## Files

- `contracts/MultiEpochVickreyAuction.sol`
  - Multi-epoch, commit-reveal, uniform clearing price auction.
  - ETH collateral model.
  - Floor update: epoch N floor = epoch N-1 winning price / 2 (from epoch 2 onward).
- `contracts/MultiEpochFixedPriceAuction.sol`
  - Multi-epoch fixed-price auction (no reveal step).
  - One order per wallet per epoch (quantity + priority tip bps).
  - Tip-priority fill when epoch is oversubscribed.
  - Listing gates for launchpad mode (ERC-8004 identity metadata + attestation verification flag).
- `contracts/MockSaleToken.sol`
  - Minimal ERC20-like token for local testing.

## Default Model Implemented

- One bid per wallet per epoch.
- Commit window + reveal window per epoch.
- Commit hash: `keccak256(abi.encodePacked(epochId, bidder, quantity, pricePerToken, salt))`.
- Uniform clearing price per epoch = `max(floor, highest losing price)`.
- Partial fill supported at cut-off.
- Non-revealed bids: penalty (`penaltyBps`) deducted from collateral.
- Winner token claim: `claimTokens(epochIds[])`.
- Refund withdrawal: `withdrawRefund(epochId)`.
- Treasury accrual and owner withdrawal.

## Fixed-Price v2 Model (Launchpad-oriented)

- No `revealBid` step (each epoch has fixed token price).
- Order input: `quantity + tipBps` with exact ETH collateral check.
- Oversubscription allocation priority: higher `tipBps`, then higher absolute tip amount.
- Partial fill and pro-rata refund are supported.
- Listing must be `active` and `attestationVerified` before orders are accepted.
- Claim and refund remain separated: `claimTokens()` and `withdrawRefund()`.

## Notes

- Quantity is treated as token base units; align frontend input/decimals accordingly.
- Owner must deposit enough sale tokens into auction contract before claims.
- This is a baseline implementation for product integration, not an audited production release.
