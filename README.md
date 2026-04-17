# TrustNet Smart Contracts

Standalone Hardhat workspace for the TrustNet auction contracts.

## Included

- `contracts/`
- `test/`
- `scripts/`
- `docs/`
  - `docs/AUCTION_BUSINESS_LOGIC_V2.md` (business logic spec before contract implementation)
  - `docs/FIXED_PRICE_CURVE.md` (geometric decay + reserve floor pricing notes)
  - `docs/AUCTION_APPLICATION_MVP.md` (application workflow + epoch model for frontend MVP)
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

Important: this workspace now assumes an 18-decimal sale token.

- For `MultiEpochVickreyAuction` and `MultiEpochFixedPriceAuction`, deployment env values like `AUCTION_TOKENS_PER_EPOCH` / `AUCTION_MAX_QTY` are entered as normal token amounts (e.g. `25000`) and converted to 18-decimal on-chain units. Bid `quantity` should be encoded with `parseUnits(value, 18)`.
- For `MultiEpochAuctionApplicationMVP`, `MVP_*` supply and quantity env values are interpreted as **whole-token counts** (e.g. `25000` means 25,000 tokens). The contract internally converts claimed transfer amounts to 18-decimal token units.

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
- `npm run deploy:mvp:local`: deploy and bootstrap `MultiEpochAuctionApplicationMVP` on Hardhat local
- `npm run deploy:mvp:testnet`: deploy and bootstrap MVP contract on `bscTestnet`
- `npm run deploy:mvp:mainnet`: deploy and bootstrap MVP contract on `bsc`

## Deployment Notes

- `deploy:local` uses Hardhat's default local signers and will deploy a `MockSaleToken` automatically.
- `deploy:testnet` and `deploy:mainnet` expect `DEPLOYER_PRIVATE_KEY` plus the relevant RPC URL in `.env`.
- Set `AUCTION_SALE_TOKEN_ADDRESS` to reuse an existing ERC-20 sale token instead of deploying `MockSaleToken`.
- Set `AUCTION_SEED_AUCTION_WITH_TOKENS=false` if you want to fund the auction inventory manually after deployment.
- If `AUCTION_TREASURY` is omitted, the deployer address is used as the treasury on remote networks.
- The commit-reveal auction (`MultiEpochVickreyAuction`) prices bids per whole token and settles collateral as `quantity * pricePerToken / 1e18` (quantity in 18-decimal token units).
- The fixed-price auction uses geometric decay + reserve floor and supports optional listing bootstrap (`FIXED_BOOTSTRAP_LISTING=true`).
- The application MVP contract (`MultiEpochAuctionApplicationMVP`) treats `quantity` as **whole-token count** (frontend-friendly). Collateral is `quantity * pricePerTokenWei`, and claimed token transfer amount is `quantity * 1e18` token units.

## Continuous Integration

GitHub Actions runs `npm ci` and `npm run smoke:local` on every push and pull request.

## Source

This workspace was assembled from the TrustNet application repository so the contracts can be developed and validated independently from the frontend and server code.
