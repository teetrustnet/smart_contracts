# Four.meme Integration (Auction Completion Launch)

This document describes how to generate token via Four.meme **after auction completion** and bind launch result to `MultiEpochAuctionApplicationMVP`.

## 1) Off-chain (Four.meme API)

Follow official flow:

1. Generate nonce
2. Sign login message + login
3. Upload image
4. Call `token/create` and obtain:
   - `createArg`
   - `signature`

This flow is implemented in backend module:

- `backend/fourmeme-client.cjs`
- `backend/service.cjs`
- `backend/server.cjs`

References:
- https://four-meme.gitbook.io/four.meme/brand/protocol-integration

## 2) On-chain preconditions

Before launch transaction:

- auction application status is `Closed`
- all epochs are finalized (`finalizeEpoch(applicationId, epochId, maxParticipants)`)
- manager is configured:
  - `setFourMemeTokenManager(0x5c952063c7fc8610FFDB798152D69F0B9550762b)` (or latest official manager)

## 3) On-chain launch call

Call:

```solidity
launchFourMemeToken(applicationId, createArgs, signature)
```

- `createArgs`: bytes from API `createArg`
- `signature`: bytes from API `signature`
- `msg.value`: include required launch fee if Four.meme requires fee

## 4) Result handling

Contract will:

- call Four.meme `TokenManager2.createToken(createArgs, signature)`
- capture new token address from manager `_tokenCount/_tokens`
- store mapping:
  - `launchedTokenByApplication[applicationId]`
  - `fourMemeLaunchExecuted[applicationId] = true`
- if `saleToken` not set, auto-bind `saleToken = launchedToken`

## 5) Operational notes

- If you plan claims from this auction contract, ensure token inventory is available to contract address.
- If Four.meme token economics route supply elsewhere by default, add treasury/creator transfer step to fund claim inventory.
- Re-launch is blocked per application by `fourMemeLaunchExecuted`.
- Backend endpoint is idempotent by checking `fourMemeLaunchExecuted(applicationId)` before launch.
