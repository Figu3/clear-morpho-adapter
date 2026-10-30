# clear-morpho-adapter

A [Morpho Vault V2](https://github.com/morpho-org/vault-v2) whose asset is Clear V1 **BaseLP**, with two contracts around it:

- `ClearMetaReserveAdapter` lets the vault supply its BaseLP to a Clear **MetaReserve** and take it back.
- `ClearZap` lets users enter and leave the vault with plain USDC or USDT.

> **Status: not audited, not deployed.** Two AI review passes have been run and their findings fixed (see [SPEC.md](SPEC.md) §8). Do not use with real funds before an external audit.

## How it works

```
user ──USDC/USDT──▶ ClearZap ──BaseLP──▶ VaultV2 (asset = BaseLP) ──BaseLP──▶ ClearMetaReserveAdapter ──▶ MetaReserve (USDS, PYUSD, USDG…)
     ◀─USDC/USDT── ClearZap ◀─BaseLP── VaultV2 ◀──BaseLP── ClearMetaReserveAdapter ◀──
```

### Clear V1 in one paragraph
Clear V1 holds liquidity in **reserves**. The **BaseReserve** holds USDC and USDT; its LP token, BaseLP, is valued at par and needs no oracle to price. A **MetaReserve** pairs BaseLP with one other stablecoin (the "native" token, e.g. USDS) at a 70/30 target. Both reserves earn by buying stablecoins that trade below their redemption price and redeeming them with the issuer. Each reserve has a **single-asset** path (deposit or withdraw one token, 10 bps fee) that only opens while every asset sits within 3 bps of its redemption price, and a **balanced** path (all legs at once, no fee, no gate).

### The vault
The vault's unit of account is BaseLP, so its share price never depends on a USD price. Idle BaseLP already earns the BaseReserve's yield. The curator can add one adapter per MetaReserve to earn the MetaReserve's yield on top, within caps.

### The adapter (`ClearMetaReserveAdapter`)
- **Allocate / deallocate** go through the MetaReserve's single-asset BaseLP path. When that path is gated (USDT more than 3 bps from its 0.9992 redemption price, which on historical data is about 70 % of the time), allocate and deallocate revert. Vault withdrawals are then served from idle BaseLP, which is why the adapter should be capped and never set as the vault's liquidity adapter.
- **`realAssets()`** values the position in BaseLP: the adapter's pro-rata claim on both MetaReserve legs (read from balances, no oracle), with the native leg converted at `min(market, redemption, $1)` over BaseLP's par value, minus an exit haircut. Only the native price reads the oracle, under try/catch:
  - oracle silent → last published price, haircut by 50 bps plus 100 bps per day of age, down to zero;
  - inside a Clear call (e.g. a flash-loan callback, when reserve balances are lent out) → revert, so nobody can price the vault on manipulated or frozen values. The lock is transient, so this only blocks that one transaction.
- **`forceDeallocate`** (Morpho's permissionless in-kind exit) is refused while the vault's penalty is below a floor, so nobody can make the vault pay exit fees for free.

### The zap (`ClearZap`)
- **Deposit**: pull USDC or USDT, try the BaseReserve single-asset deposit; if it reverts, do a balanced deposit and buy the other leg. Then deposit the BaseLP into the vault for the receiver.
- **Redeem**: redeem the caller's shares for BaseLP, try the single-asset withdrawal; if it reverts, withdraw pro rata and sell the other leg.
- **Where the other leg trades** is chosen by `swapData`:
  - empty: the Uniswap V3 USDC/USDT 1 bp pool, fully on-chain, so contracts can always use it;
  - a KyberSwap route built off-chain (sender and recipient = the zap), executed on the KyberSwap `MetaAggregationRouterV2`: better execution for size. `previewBalancedDeposit` / `previewBalancedRedeem` give the amounts to quote. The route is untrusted: exact allowance reset to zero, result measured by balance deltas, oracle bound applied, re-entry blocked.
- Every swap is bounded twice: by the caller's `minShares` / `minAmountOut`, and by the live oracle cross-rate less 5 bps. The zap is stateless and returns dust to the caller.

## Run

```bash
forge install foundry-rs/forge-std --no-git
```

```bash
ETH_RPC_URL=<archive mainnet RPC> forge test
```

Tests fork mainnet at block 26,299,058 (override with `FORK_BLOCK`) and are skipped without `ETH_RPC_URL`. The fixture pushes oracle prices by pranking the PythOracleAdapter (it holds the updater role), seeds the live BaseReserve and MetaReserve (empty at that block), and wires a fresh `VaultV2`. The adapter suite runs twice: on the USDS MetaReserve (18-decimal native) and on PYUSD (6 decimals).

`test/ClearZapKyberLive.fork.t.sol` runs a real KyberSwap route through the zap and is skipped by default. Run it in two passes on one recent block: with `KYBER_LIVE=true FORK_BLOCK=<block>` it fails with `PREPARE zap=<address> usdtToSell=<amount>`; build a USDT to USDC route for that amount with the Kyber API (sender and recipient = that address), then rerun with `KYBER_SWAP_DATA=<calldata>` and `KYBER_USDT_PRICE_8=<the route's USDT price, 8 decimals>`.

## Layout

| Path | What |
|---|---|
| `src/ClearMetaReserveAdapter.sol` | Morpho adapter (BaseLP <-> MetaLP) |
| `src/ClearZap.sol` | USDC/USDT <-> vault shares |
| `src/interfaces/IClear.sol` | Subset of the Clear V1 ABI |
| `test/ClearForkBase.sol` | Fork fixture and the spec formulas, written independently of the contracts |
| `test/ClearMetaReserveAdapter.fork.t.sol` | Adapter, SPEC §7 (USDS and PYUSD) |
| `test/ClearZap.fork.t.sol` | Zap, SPEC §7 (including gate-closed exits) |
| `test/ClearZapAggregator.fork.t.sol` | Zap aggregator route against a mock router: fair, bad rate, over-pull, wrong recipient, re-entry |
| `test/ClearZapKyberLive.fork.t.sol` | Zap exit through the real KyberSwap router (manual, two passes) |
| `test/Clear.invariant.t.sol` | Stateful fuzzing: allocations, prices, staleness, depeg swaps, zap flows |
| `test/FlashLoanPoC.fork.t.sol` | Regressions for Clear flash loans and the open global lock (`isolate` mode) |
| `lib/morpho-vault-v2` | Vendored `VaultV2.sol` + interfaces/libraries, commit in `VERSION` |
