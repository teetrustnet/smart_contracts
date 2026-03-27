# Fixed-Price Curve (v2)

This document explains the updated fixed-price epoch curve used by `MultiEpochFixedPriceAuction`.

## Formula

For epoch `e >= 1`:

- `price(1) = initialPrice`
- `price(e) = max(reservePrice, initialPrice * ((BPS - decayBps) / BPS)^(e-1))`

Where:

- `BPS = 10_000`
- `decayBps` is configured in constructor (e.g. `200` = 2% per epoch)
- `reservePrice` is a hard floor (price never drops below this)

## Why this is better than linear decay

- Smoother trajectory over many epochs
- Better early-stage price continuity
- Avoids collapsing too fast when epoch count is high
- Reserve floor makes long-tail epochs predictable

## Example

- `initialPrice = 1.0`
- `decayBps = 2000` (20%)
- `reservePrice = 0.25`

Then:

- Epoch 1: `1.000000`
- Epoch 2: `0.800000`
- Epoch 3: `0.640000`
- Epoch 4: `0.512000`
- Epoch 5: `0.409600`
- Epoch 6: `0.327680`
- Epoch 7: `0.262144`
- Epoch 8+: `0.250000` (floor)

## Frontend helper

Use `getEpochPriceBatch(fromEpoch, toEpoch)` for rendering the curve efficiently in UI.
