# TrustNet Smart Contracts

Standalone Hardhat workspace for the TrustNet auction contracts.

## Included

- `contracts/`
- `test/`
- `scripts/`
- `docs/`
  - `docs/AUCTION_BUSINESS_LOGIC_V2.md` (business logic spec before contract implementation)
  - `docs/FIXED_PRICE_CURVE.md` (geometric decay + reserve floor pricing notes)
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

Important: this workspace now assumes an 18-decimal sale token. `AUCTION_TOKENS_PER_EPOCH` and `AUCTION_MAX_QTY` in `.env` are entered as normal token amounts such as `25000`, and the deployment script converts them to 18-decimal on-chain units. On-chain bid `quantity` values should also be encoded with `parseUnits(value, 18)`, while `pricePerToken` stays in wei per whole token.

## Scripts

- `npm run compile`: compile contracts
- `npm run test`: run the contract test suite
- `npm run smoke:local`: compile, test, and do a local deployment
- `npm run deploy:local`: deploy commit-reveal auction to Hardhat's local in-process network
- `npm run deploy:testnet`: deploy commit-reveal auction to `bscTestnet` using `.env`
- `npm run deploy:mainnet`: deploy commit-reveal auction to `bsc` using `.env`
- `npm run deploy:fixed:local`: deploy fixed-price auction to Hardhat local
- `npm run deploy:fixed:testnet`: deploy fixed-price auction to `bscTestnet`
- `npm run deploy:fixed:mainnet`: deploy fixed-price auction to `bsc`

## Deployment Notes

- `deploy:local` uses Hardhat's default local signers and will deploy a `MockSaleToken` automatically.
- `deploy:testnet` and `deploy:mainnet` expect `DEPLOYER_PRIVATE_KEY` plus the relevant RPC URL in `.env`.
- Set `AUCTION_SALE_TOKEN_ADDRESS` to reuse an existing ERC-20 sale token instead of deploying `MockSaleToken`.
- Set `AUCTION_SEED_AUCTION_WITH_TOKENS=false` if you want to fund the auction inventory manually after deployment.
- If `AUCTION_TREASURY` is omitted, the deployer address is used as the treasury on remote networks.
- The commit-reveal auction prices bids per whole token and settles collateral as `quantity * pricePerToken / 1e18`.
- The fixed-price auction uses geometric decay + reserve floor and supports optional listing bootstrap (`FIXED_BOOTSTRAP_LISTING=true`).

## Continuous Integration

GitHub Actions runs `npm ci` and `npm run smoke:local` on every push and pull request.

## Source

This workspace was assembled from the TrustNet application repository so the contracts can be developed and validated independently from the frontend and server code.
