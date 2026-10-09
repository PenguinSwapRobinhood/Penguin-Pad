# Audit

Audit of the Penguin Pad contracts on Robinhood Chain mainnet (chain id 4663), completed 26 September 2026. Revised 8 October 2026 for the new curve factory.

## Scope

In scope:

| Contract | Address |
| --- | --- |
| CurveFactory | this source; new quick launches only |
| CurveLaunch | deployed per quick launch by that factory |
| PresaleFactory | `0x2d49B4B881CD27b917e4321839fc4B28a95d12a0` |
| Presale and PenguinToken | deployed per sale by PresaleFactory |
| PenguinHook | `0x19B4517dED421d738051545e6C5d461ef13460cc` |
| V4Graduate | `0x4aE34aDDDDA5f74E6bBf2AA4E7fa1709C4A02f55` |

Quick launches already created stay on the previous CurveFactory, `0x09f1B640d53C9C4C1807BF5Aa306745128Ee4375`. Those tokens keep the phantom stored at their create. This repository's `CurveFactory`, `CurveLaunch`, and curve phantom are the new factory. Presale, PenguinHook, and V4Graduate are unchanged. Reproducing the previous curve factory bytecode, or the live PresaleFactory bytecode, requires the prior revision of `LibMath.sol`.

Out of scope: the website, wallet software, Uniswap v4 core (PoolManager and PositionManager), and Robinhood Chain itself.

## How this was checked

The deployed source was read against the intended flows: curve buy and sell, graduation, presale contribute, withdraw, cancel, finalize, claim, and refund. Fee splits, the burned liquidity position, and the hook's restriction on who may initialize a pool were checked in the code.

## Result

No path was found that lets a stranger pull the curve inventory, take contributor ETH out of an open presale, or move a burned liquidity position. The notes below are limits of the design. They are not hidden admin powers.

## Design

Quick launch. The launch contract is the token. Buys transfer tokens immediately. ETH taken by the curve stays in the contract until graduation or a sell. At the graduation amount, that same transaction seeds the Uniswap v4 pool and marks the curve closed. The position NFT is minted to the dead address.

The production phantom is 1.4 ETH. At a 4.2 ETH graduation the last curve price equals the pool open: 4.2 ETH against the 200,000,000 tokens seeded into the pool.

Token owner. `owner()` on each new CurveLaunch is the zero address. `initialize` emits `OwnershipTransferred` from the factory to the zero address before the first trade. `renounceOwnership` emits that event again and changes nothing. The creator is the fee recipient, not an owner. There is no owner-only function on the token.

Presale. ETH is pledged. Tokens stay in the presale until a successful finalize. Buyers then call `claim()`. The creator is paid ETH only: 3% of the raise goes to the fee wallet, then `creatorPct` (0-30) of the remainder goes to the creator, and the rest seeds the pool. The creator is not minted a token allocation. Unsold hard-cap tokens are burned. A missed soft cap or a cancel pays ETH back through `refund()`.

Hook. PenguinHook charges 1% on swaps in the official pool and splits it 75% to the listing creator and 25% to the current fee wallet. `beforeInitialize` accepts the pool only when the caller is V4Graduate, the token was registered in that seed, and the fee and tick spacing match the official pool. A pool that does not use this hook is a different pool. It does not occupy the official pool id, and it cannot spend the launch contract's remaining tokens or ETH.

Factory owner. On each factory the owner may set the fee wallet, transfer ownership, or call `lockProduction` once. `transferOwnership` rejects the zero address, so the factory itself is not renounced. There is no pause, no fee editor, and no function that sweeps ETH out of a live sale.

## Notes

1. Curve buys have no per-wallet maximum. One address can buy the remaining curve and trigger graduation. The five-second snipe tax raises the cost of the earliest buys. It does not cap size.

2. The presale per-wallet maximum is set by the creator and may be equal to the hard cap. In that case one wallet can fund the entire sale. The contract enforces the configured maximum. It does not impose a smaller one.

3. Changing `penguinProtocol` redirects future fee payouts. It does not move ETH already paid, and it does not change buyer claims.

4. A buyer can move tokens they already received and can pool those tokens elsewhere before graduation. That pool cannot debit the launch contract. Graduation of the official pool does not depend on it.

5. There is no admin recovery for ETH forced into a contract. A general sweep would also let the owner take contributor funds, so it was left out. Failed presales pay contributors through `refund()`. A successful finalize pays the fee wallet, the creator, and the pool, then sends any leftover ETH on the presale to the fee wallet.

6. If the creator's address rejects ETH during graduation or finalize, that creator share is retained for `claimCreatorFees()` on the curve, or handled by the presale's payout path. Buyer claims are a separate token transfer and do not depend on the creator accepting ETH.
