# Penguin Pad

Penguin Pad is a launchpad on Robinhood Chain (chain id 4663). A creator can open a quick launch on a bonding curve, or a presale. Both list on Uniswap v4. The pool uses PenguinHook. The opening liquidity position is sent to `0x000000000000000000000000000000000000dEaD` and is not recoverable.

The contracts in this repository are not proxies. There is no upgrade path. New quick launches use the CurveFactory in this source. Tokens already created stay on the old CurveFactory.

## Addresses

| Contract | Address |
| --- | --- |
| CurveFactory | `0x6747bcc869c39d964A36E4796bead3FA3b377b73` |
| Old CurveFactory | `0x09f1B640d53C9C4C1807BF5Aa306745128Ee4375` |
| PresaleFactory | `0x2d49B4B881CD27b917e4321839fc4B28a95d12a0` |
| PenguinHook | `0x19B4517dED421d738051545e6C5d461ef13460cc` |
| V4Graduate | `0x4aE34aDDDDA5f74E6bBf2AA4E7fa1709C4A02f55` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Fee wallet (`penguinProtocol`) | `0x831239B4930912329bC251baD7749C701f671d0a` |
| Owner | `0x198A004f8433e79e307c25E10bc87bA83095a45a` |

Explorer: [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com)

## Quick launch

`CurveFactory.createLaunch` deploys a `CurveLaunch`. That contract is the ERC-20. Supply is fixed at 1,000,000,000 tokens. 800,000,000 sit on the curve. The remaining 200,000,000 seed the pool at graduation.

A buy pays ETH and receives tokens in the same transaction. A sell returns tokens and receives ETH while the curve is open. There is no per-wallet buy cap. One address can buy the curve.

The curve graduates when net ETH raised reaches the graduation amount stored on that listing. The buy that crosses the line is filled first. Unused ETH on that buy is refunded. The ETH held for the curve and the unsold tokens are then seeded into the v4 pool. Curve buys and sells revert after that. Later trades go through the pool.

The first five seconds of buys pay a decaying snipe tax straight to the fee wallet. The standing 1% trade fee accrues during the curve (75% creator, 25% fee wallet) and is paid in the graduation transaction. After listing, PenguinHook takes 1% on each swap and pays it on that swap.

## Presale

`PresaleFactory.createPresale` deploys a `Presale` and a `PenguinToken`. Contributors send ETH during the scheduled window. They do not receive tokens at that time. The contract records the pledge.

The creator sets the presale rate (tokens per 1 ETH for buyers), the listing rate (tokens per 1 ETH of liquidity), the schedule, soft and hard caps, and a per-wallet minimum and maximum. The listing rate must be greater than zero and no higher than the presale rate, so the pool cannot open below the presale price. The soft cap must be at least 25% of the hard cap, and at least the factory minimum.

`creatorPct` is an integer from 0 to 30. After a 3% fee to the fee wallet, that percent of the remaining ETH is paid to the creator on finalize. The creator receives no tokens. The rest of the ETH, with tokens at the listing rate, seeds the pool. Unsold tokens from the hard-cap mint are burned.

Finalize is not automatic and is not open to the public. The creator, or the current fee wallet, can finalize when the hard cap is met, or when the end time has passed and the soft cap has been met. After a successful finalize, each contributor calls `claim()` for `contributed * presaleRate / 1e18` tokens.

If the soft cap is missed, or the sale is cancelled, contributors call `refund()` for their ETH. No buyer tokens are issued.

The per-wallet maximum is chosen by the creator. It cannot exceed the hard cap. If the creator sets it equal to the hard cap, one wallet can fund the sale.

## Owner

The deployer is the owner of both factories. The owner can:

- `setPenguinProtocol` to point future fee payouts at a new wallet. Listings read the live wallet. They do not store it at creation.
- `transferOwnership`
- `lockProduction` once, on each factory

The owner cannot pause trading, change fee rates, seize listings, or withdraw contributor ETH. There is no general recover function.

## Build

Solidity 0.8.24, optimizer on, 200 runs, via IR, EVM shanghai, `bytecodeHash` none. That matches `foundry.toml`.

`LibMath.sol` in this tree is the library for the CurveFactory above. The production phantom is 1.4 ETH. The old CurveFactory, the live PresaleFactory, PenguinHook, and V4Graduate were compiled from the prior revision of that library. To reproduce those bytecodes, use the Standard JSON already submitted for each address on Blockscout.

```bash
forge build
```
