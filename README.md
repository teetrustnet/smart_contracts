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
- `npm run test:backend`: run backend integration unit tests
- `npm run smoke:local`: compile + all tests
- `npm run deploy:mvp:local`: deploy MVP to Hardhat local
- `npm run deploy:mvp:testnet`: deploy MVP to bscTestnet
- `npm run deploy:mvp:mainnet`: deploy MVP to bsc
- `npm run backend:start`: start backend launch API service

## Environment

Copy `.env.example` to `.env` and fill required fields.

```bash
cp .env.example .env
```

Important MVP semantics:

- `quantity` is interpreted as **whole-token count**.
- collateral is `quantity * pricePerTokenWei`.
- claimed transfer amount is `quantity * tokenUnitScale` (auto-detected from token decimals; fallback 1e18).

## MVP Highlights

- Application lifecycle: `draft -> submitted -> approved -> live -> closed` (plus `rejected`)
- Per-epoch `price + supply` config
- Curve initializer supports front-high/back-low model (e.g. last epoch price 50% of epoch 1, last epoch supply 2%)
- Legacy compatibility path: `commitBid(epochId, commitment)` + `revealBid(...)`
- One-step path: `commitBid(epochId, quantity, pricePerToken, salt)`
- Runtime view helpers for frontend snapshot and epoch summary
- Post-auction Four.meme token launch hook:
  - `setFourMemeTokenManager(address)`
  - `launchFourMemeToken(applicationId, createArgs, signature)` (payable)

## Backend Integration API (Four.meme)

A minimal backend service is included at `backend/server.cjs`.

- Health check: `GET /healthz`
- Launch endpoint: `POST /auction/:applicationId/fourmeme/launch`

Example curl:

```bash
curl -X POST "http://localhost:8787/auction/1/fourmeme/launch" \
  -H "Content-Type: application/json" \
  -d '{
    "launchFeeWei": "0",
    "createTokenRequest": {
      "name": "RELEASE",
      "shortName": "RELS",
      "desc": "RELEASE DESC",
      "imgUrl": "https://static.four.meme/market/example.png",
      "launchTime": 1740708849097,
      "label": "AI",
      "lpTradingFee": 0.0025,
      "webUrl": "https://example.com",
      "twitterUrl": "https://x.com/example",
      "telegramUrl": "https://t.me/example",
      "preSale": "0",
      "onlyMPC": false,
      "feePlan": false,
      "raisedToken": {
        "symbol": "BNB",
        "nativeSymbol": "BNB",
        "symbolAddress": "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c",
        "deployCost": "0",
        "buyFee": "0.01",
        "sellFee": "0.01",
        "minTradeFee": "0",
        "b0Amount": "8",
        "totalBAmount": "24",
        "totalAmount": "1000000000",
        "logoUrl": "https://static.four.meme/market/example.png",
        "tradeLevel": ["0.1", "0.5", "1"],
        "status": "PUBLISH",
        "buyTokenLink": "https://pancakeswap.finance/swap",
        "reservedNumber": 10,
        "saleRate": "0.8",
        "networkCode": "BSC",
        "platform": "MEME"
      }
    }
  }'
```

## Docs

- `docs/AUCTION_APPLICATION_MVP.md`
- `docs/FOUR_MEME_INTEGRATION.md`
- `docs/SECURITY_AUDIT_3L_2026-04-17.md`
- `contracts/README.md`
