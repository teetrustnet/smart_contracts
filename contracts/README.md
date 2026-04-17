# Auction Solidity Contracts

## Active Contract

- `contracts/MultiEpochAuctionApplicationMVP.sol`

## Model

- Application workflow:
  - `createAuctionApplication`
  - `submitAuctionApplication`
  - `approveAuctionApplication`
  - `launchAuctionApplication`
  - `closeAuctionApplication`
  - optional rejection via `rejectAuctionApplication`
- Per-epoch independent `price + supply`
- Optional curve bootstrap via `initializeEpochCurve`
- Runtime reads for frontend:
  - `currentEpoch`, `currentPhase`, `currentEpochRemainingTokens`
  - `getEpochSummary`, `getEpochSummaryDetailed`
- Bid entry:
  - legacy commit/reveal: `commitBid(epochId, commitment)` + `revealBid(...)`
  - one-step commit: `commitBid(epochId, quantity, pricePerToken, salt)`

## Quantity / Value Semantics

- Quantity is **whole-token count**.
- Payment is quoted in wei: `quantity * pricePerTokenWei`.
- Claim transfers `quantity * 1e18` token units.

## Notes

- Owner must seed enough sale token inventory before users claim.
- This is an integration MVP; production deployment still requires full third-party audit.
