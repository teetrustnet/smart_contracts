# TrustNet Smart Contracts

Standalone Hardhat workspace for TrustNet auction contracts.

## Scope (current)

This repo now keeps **only one active auction contract**:

- `contracts/MultiEpochAuctionApplicationMVP.sol`

Legacy contracts have been removed to reduce maintenance surface.

## Quick Start

```bash
npm install
npm run compile
npm run test
npm run smoke:local
```

## Scripts

- `npm run compile`: compile contracts
- `npm run test`: run contract tests
- `npm run smoke:local`: compile + test
- `npm run deploy:mvp:local`: deploy MVP to Hardhat local
- `npm run deploy:mvp:testnet`: deploy MVP to bscTestnet
- `npm run deploy:mvp:mainnet`: deploy MVP to bsc

## Environment

Copy `.env.example` to `.env` and fill required fields.

```bash
cp .env.example .env
```

Important MVP semantics:

- `quantity` is interpreted as **whole-token count**.
- collateral is `quantity * pricePerTokenWei`.
- claimed transfer amount is `quantity * 1e18` token units.

## MVP Highlights

- Application lifecycle: `draft -> submitted -> approved -> live -> closed` (plus `rejected`)
- Per-epoch `price + supply` config
- Curve initializer supports front-high/back-low model (e.g. last epoch price 50% of epoch 1, last epoch supply 2%)
- Legacy compatibility path: `commitBid(epochId, commitment)` + `revealBid(...)`
- One-step path: `commitBid(epochId, quantity, pricePerToken, salt)`
- Runtime view helpers for frontend snapshot and epoch summary

## Docs

- `docs/AUCTION_APPLICATION_MVP.md`
- `contracts/README.md`
