# TrustNet Smart Contracts

Standalone Hardhat workspace for the TrustNet auction contracts.

## Included

- `contracts/`
- `test/`
- `scripts/`
- `hardhat.config.cjs`
- `.github/workflows/ci.yml`
- `.env.example`

## Quick Start

```bash
npm install
npm run compile
npm run test
npm run smoke:local
```

`smoke:local` runs compile, tests, and a local deployment on Hardhat's in-process network.

## Environment Setup

Copy `.env.example` to `.env` and fill in the values you need for the target network.

```bash
cp .env.example .env
```

Important: `AUCTION_TOKENS_PER_EPOCH` and `AUCTION_MAX_QTY` are raw token units, not "human readable" token counts. If your sale token uses 18 decimals and you want to auction 25,000 whole tokens per epoch, the value must be `25000000000000000000000`.

## Scripts

- `npm run compile`: compile contracts
- `npm run test`: run the contract test suite
- `npm run smoke:local`: compile, test, and do a local deployment
- `npm run deploy:local`: deploy to Hardhat's local in-process network
- `npm run deploy:testnet`: deploy to `bscTestnet` using `.env`
- `npm run deploy:mainnet`: deploy to `bsc` using `.env`

## Deployment Notes

- `deploy:local` uses Hardhat's default local signers and will deploy a `MockSaleToken` automatically.
- `deploy:testnet` and `deploy:mainnet` expect `DEPLOYER_PRIVATE_KEY` plus the relevant RPC URL in `.env`.
- Set `AUCTION_SALE_TOKEN_ADDRESS` to reuse an existing ERC-20 sale token instead of deploying `MockSaleToken`.
- Set `AUCTION_SEED_AUCTION_WITH_TOKENS=false` if you want to fund the auction inventory manually after deployment.
- If `AUCTION_TREASURY` is omitted, the deployer address is used as the treasury on remote networks.

## Continuous Integration

GitHub Actions runs `npm ci` and `npm run smoke:local` on every push and pull request.

## Source

This workspace was assembled from the TrustNet application repository so the contracts can be developed and validated independently from the frontend and server code.
