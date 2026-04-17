# Auction Application MVP (TrustNet-Web aligned)

Contract: `contracts/MultiEpochAuctionApplicationMVP.sol`

## Why this contract

This MVP is designed to match current TrustNet-Web auction pages (`AuctionLandingPage` + `AuctionStartPage`) and keeps key ABI compatibility with existing `useEthersAuction` flows.

## Core capabilities

1. **Auction configuration**
   - Default-ready for `20` epochs and `180s` epoch duration (3 minutes)
   - Configurable per application

2. **Independent epoch `price + supply`**
   - Manual configuration:
     - `setEpochConfig(applicationId, epochId, pricePerTokenWei, supplyTokens)`
     - `setEpochConfigs(applicationId, prices[], supplies[])`
   - Model initializer:
     - `initializeEpochCurve(applicationId, firstEpochPriceWei, lastEpochPriceBps, totalSupplyTokens, lastEpochSupplyBps)`
     - Example target: `lastEpochPriceBps=5000` (epoch 20 = 50% of epoch 1), `lastEpochSupplyBps=200` (epoch 20 = 2% total supply)

3. **Commit bid interfaces**
   - Legacy compatibility:
     - `commitBid(uint256 epochId, bytes32 commitment)`
     - `revealBid(uint256 epochId, uint256 quantity, uint256 pricePerToken, bytes32 salt)`
   - One-step frontend-friendly:
     - `commitBid(uint256 epochId, uint256 quantity, uint256 pricePerToken, bytes32 salt)`

4. **State reads for frontend**
   - `currentEpoch()`
   - `currentPhase()`
   - `currentEpochRemainingTokens()`
   - `getCurrentEpochState()`
   - `getEpochSummary(epochId)`
   - `getEpochSummaryDetailed(epochId)`

5. **Application review state machine**
   - `draft -> submitted -> approved -> live -> closed`
   - Optional reject branch: `rejected`

## Quantity & payment model

- `quantity` is interpreted as **whole-token count** (aligned with frontend input).
- Collateral/payment in wei: `quantity * pricePerTokenWei`.
- Claims transfer ERC-20 token units as: `quantity * tokenUnitScale` (auto-detected from token decimals, fallback 1e18).

## Four.meme integration (post-auction token generation)

This contract now supports generating a token on four.meme **after auction completion**.

### On-chain prerequisites

1. Configure manager address:
   - `setFourMemeTokenManager(address)`
2. Auction must be:
   - `status == Closed`
   - all epochs finalized

### Launch call

Use:

- `launchFourMemeToken(applicationId, createArgs, signature)` (payable)

Where:
- `createArgs` and `signature` come from four.meme `token/create` API response.
- `msg.value` should include required launch fee (if any).

### Result

- `launchedTokenByApplication[applicationId]` stores created token address (derived from four.meme manager `_tokenCount/_tokens`).
- If `saleToken` is not configured yet, it is auto-bound to the launched token.

## Deployment bootstrap

Script: `scripts/deploy-auction-mvp.cjs`

- Creates application
- Initializes epoch curve
- Submits + approves + launches
- Optionally seeds sale token inventory

Run examples:

```bash
npm run deploy:mvp:local
npm run deploy:mvp:testnet
npm run deploy:mvp:mainnet
```
