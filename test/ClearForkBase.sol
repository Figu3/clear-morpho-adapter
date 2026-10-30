// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {VaultV2} from "vault-v2/VaultV2.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

import {ClearMetaReserveAdapter} from "../src/ClearMetaReserveAdapter.sol";
import {ClearZap} from "../src/ClearZap.sol";
import {IClearBaseReserve, IClearMetaReserve, IClearOracle, IAccessManagerLike} from "../src/interfaces/IClear.sol";

/// @dev USDT returns nothing from approve/transfer, so the tests call every token through this shape.
interface IERC20Loose {
    function approve(address spender, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external;
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV3PoolLike {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

interface ISwapRouter02Like {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Mainnet fork fixture: the live Clear V1 BaseReserve and native MetaReserve, the live oracle
///         (prices pushed by pranking the PythOracleAdapter, which holds the updater role), a fresh
///         Morpho VaultV2 whose asset is BaseLP, the MetaReserve adapter and the zap.
/// @dev    Needs ETH_RPC_URL (an archive-capable RPC). Every test is skipped without it.
abstract contract ClearForkBase is Test {
    // ---- Mainnet addresses (Clear V1, deployed 2026-10-27; registry v1.0) ----
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant BASE_RESERVE = 0xd1b4d7F6f651c13b687A22fC97B718AAD3A0E41D;
    address internal constant META_USDS = 0x070f56b62E3352D6D8fA52024Bbf4C51d6917317;
    address internal constant CLEAR_ORACLE = 0x323F9737f4A2763FA419bD679ce0D7a2bc322a30;
    address internal constant PYTH_ORACLE_ADAPTER = 0x39b548E590eC3B6333a200fa715F9eAb04F76858;
    address internal constant ACCESS_MANAGER = 0x5601D10AB86d2b119F169232Baab39b317dD498E;
    address internal constant ADMIN_SAFE = 0x5cB07DCeef724812373251156B46444216d733AB;
    address internal constant UNI_USDC_USDT_100 = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address internal constant UNI_SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    /// @dev KyberSwap MetaAggregationRouterV2.
    address internal constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    uint64 internal constant PAUSER_ROLE = 3;

    /// @dev Block the fork is pinned to by default (2026-10-29). Override with FORK_BLOCK.
    uint256 internal constant DEFAULT_FORK_BLOCK = 26_299_058;

    uint256 internal constant BPS = 10_000;

    // ---- Oracle prices, 8 decimals. Live redemption prices: USDC 1, USDT 0.9992, native 0.9999. ----
    uint256 internal constant PAR_8 = 1e8;
    uint256 internal constant USDT_REDEMPTION_8 = 0.9992e8;
    /// @dev Within `redemptionProximityBps` (3) of the redemption price: single-asset paths open.
    uint256 internal constant USDT_GATE_OPEN_8 = 0.9992e8;
    /// @dev USDT at par is 8 bps above its redemption price: single-asset paths CLOSED, on the
    ///      BaseReserve and on every MetaReserve (which checks `baseReserve.assetsOnPeg`).
    uint256 internal constant USDT_AT_PAR_8 = 1e8;
    uint256 internal constant NATIVE_ON_PEG_8 = 0.9999e8;
    /// @dev 50 bps under its redemption price: the MetaReserve depeg route (native in, BaseLP out) opens.
    uint256 internal constant NATIVE_DEPEG_8 = 0.995e8;

    // ---- Parameters under test ----
    uint256 internal constant EXIT_FEE_BPS = 15;
    uint256 internal constant STALE_HAIRCUT_BPS = 50;
    /// @dev The stale haircut grows by this much per day of oracle silence (native leg at 0 after ~99 days).
    uint256 internal constant STALE_DECAY_BPS_PER_DAY = 100;
    uint256 internal constant MIN_FORCE_DEALLOCATE_PENALTY = 0.002e18;
    uint256 internal constant MAX_SWAP_SLIPPAGE_BPS = 5;
    uint256 internal constant FORCE_DEALLOCATE_PENALTY = 0.002e18; // 20 bps >= exit cost
    uint256 internal constant MAX_RATE = uint256(0.2e18) / 365 days; // 20 % APR

    uint256 internal constant BASE_SEED_PAR = 4_000_000e18;
    uint256 internal constant META_SEED_BASE_LP = 1_400_000e18;
    uint256 internal constant VAULT_SEED_PAR = 1_000_000e18;

    IClearBaseReserve internal base = IClearBaseReserve(BASE_RESERVE);
    IClearOracle internal clearOracle = IClearOracle(CLEAR_ORACLE);

    /// @dev The MetaReserve under test and its native token, chosen by {_selectMetaReserve}.
    address internal metaAddr;
    address internal native;
    IClearMetaReserve internal meta;

    VaultV2 internal vault;
    ClearMetaReserveAdapter internal adapter;
    ClearZap internal zap;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal alice = makeAddr("alice");

    function setUp() public virtual {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));

        metaAddr = _selectMetaReserve();
        meta = IClearMetaReserve(metaAddr);
        native = meta.nativeToken();

        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_ON_PEG_8);
        _seedReserves();
        _deployVault();
        _depositBaseLpToVault(alice, _mintBaseLp(alice, VAULT_SEED_PAR));
    }

    // ---------------------------------------------------------------------
    // Fixture
    // ---------------------------------------------------------------------

    /// @dev USDS (18 decimals) by default; override to run the same suite on another MetaReserve.
    function _selectMetaReserve() internal pure virtual returns (address) {
        return META_USDS;
    }

    /// @dev `whole` units of the native token, in its own decimals (USDS 18, PYUSD/USDG 6).
    function _nativeAmount(uint256 whole) internal view returns (uint256) {
        return whole * 1e18 / meta.nativeScale();
    }

    function _seedReserves() internal {
        address seeder = makeAddr("reserveSeeder");
        uint256 lp = _mintBaseLp(seeder, BASE_SEED_PAR);
        assertGe(lp, META_SEED_BASE_LP);

        uint256 nativeIn = meta.previewDepositNative(META_SEED_BASE_LP);
        deal(native, seeder, nativeIn);
        vm.startPrank(seeder);
        base.approve(metaAddr, META_SEED_BASE_LP);
        IERC20Loose(native).approve(metaAddr, nativeIn);
        meta.deposit(META_SEED_BASE_LP, nativeIn, seeder, 0);
        vm.stopPrank();
    }

    function _deployVault() internal {
        vault = new VaultV2(owner, BASE_RESERVE);
        adapter = _newAdapter(address(vault));
        zap = new ClearZap(address(vault), CLEAR_ORACLE, UNI_USDC_USDT_100, KYBER_ROUTER, MAX_SWAP_SLIPPAGE_BPS);

        vm.prank(owner);
        vault.setCurator(curator);

        _curate(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        _curate(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        bytes[] memory idsData = adapter.idsData();
        for (uint256 i; i < idsData.length; ++i) {
            _curate(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idsData[i], type(uint128).max)));
            _curate(abi.encodeCall(IVaultV2.increaseRelativeCap, (idsData[i], 1e18)));
        }
        _curate(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), FORCE_DEALLOCATE_PENALTY)));

        vm.prank(allocator);
        vault.setMaxRate(MAX_RATE);
    }

    function _newAdapter(address parentVault) internal returns (ClearMetaReserveAdapter) {
        return new ClearMetaReserveAdapter(
            ClearMetaReserveAdapter.Params({
                parentVault: parentVault,
                metaReserve: metaAddr,
                oracle: CLEAR_ORACLE,
                exitFeeBps: EXIT_FEE_BPS,
                staleHaircutBps: STALE_HAIRCUT_BPS,
                staleDecayBpsPerDay: STALE_DECAY_BPS_PER_DAY,
                minForceDeallocatePenalty: MIN_FORCE_DEALLOCATE_PENALTY
            })
        );
    }

    /// @dev Timelocks are zero on a fresh vault: submit then execute in the same block.
    function _curate(bytes memory data) internal {
        vm.prank(curator);
        vault.submit(data);
        vm.prank(curator);
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ---------------------------------------------------------------------
    // Oracle
    // ---------------------------------------------------------------------

    /// @dev Advances one second so the publish time is strictly newer than the last one, as
    ///      {ClearOracle} requires.
    function _pushPrices(uint256 usdc8, uint256 usdt8, uint256 usds8) internal {
        vm.warp(block.timestamp + 1);
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = USDT;
        assets[2] = native;
        uint256[] memory prices = new uint256[](3);
        prices[0] = usdc8;
        prices[1] = usdt8;
        prices[2] = usds8;
        uint256[] memory times = new uint256[](3);
        times[0] = block.timestamp;
        times[1] = block.timestamp;
        times[2] = block.timestamp;
        vm.prank(PYTH_ORACLE_ADAPTER);
        clearOracle.updateCustomOraclePrices(assets, prices, times);
    }

    function _makeOracleStale() internal {
        (,,,, uint256 ttl,,) = clearOracle.oracleConfiguration(native);
        vm.warp(block.timestamp + ttl + 1);
    }

    /// @dev USDT's USD price implied by the Uniswap USDC/USDT 1 bp pool (USDC = $1), 8 decimals.
    ///      token0 = USDC, token1 = USDT, same decimals, so price(token1/token0) = (sqrtP / 2^96)^2.
    function _poolUsdtPrice8() internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IUniswapV3PoolLike(UNI_USDC_USDT_100).slot0();
        uint256 usdtPerUsdcX96 = (uint256(sqrtP) * uint256(sqrtP)) >> 96;
        return (PAR_8 << 96) / usdtPerUsdcX96;
    }

    /// @dev Closes the single-asset gate the way the market does: if the pool quotes USDT inside the
    ///      gate band (within 4 bps of 0.9992), buy USDT on the pool until it trades at 0.99975, then push
    ///      an oracle that agrees with the pool. The conditions the balanced zap path exists for.
    function _pushPoolPricesGateClosed() internal {
        uint256 p = _poolUsdtPrice8();
        if (p < USDT_REDEMPTION_8 + 0.0004e8 && p > USDT_REDEMPTION_8 - 0.0004e8) {
            _movePoolUsdtTo(0.99975e18);
            p = _poolUsdtPrice8();
        }
        _pushPrices(PAR_8, p, NATIVE_ON_PEG_8);
    }

    /// @dev Swaps USDC for USDT on the pool up to the sqrt price at which USDT trades at `usdtPrice`
    ///      (1e18). price(token1/token0) = 1 / usdtPrice, so sqrtP = 2^96 / sqrt(usdtPrice).
    function _movePoolUsdtTo(uint256 usdtPrice) internal {
        address mover = makeAddr("poolMover");
        uint256 amount = 400_000_000e6;
        deal(USDC, mover, amount);
        uint160 limit = uint160((uint256(1) << 96) * 1e9 / _sqrtWad(usdtPrice));
        vm.startPrank(mover);
        IERC20Loose(USDC).approve(UNI_SWAP_ROUTER_02, amount);
        ISwapRouter02Like(UNI_SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02Like.ExactInputSingleParams(USDC, USDT, 100, mover, amount, 0, limit)
        );
        vm.stopPrank();
    }

    function _sqrtWad(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    /// @dev Mints BaseLP to `who` through a balanced BaseReserve deposit of `par` (1e18) total value.
    function _mintBaseLp(address who, uint256 par) internal returns (uint256 lp) {
        (uint256[] memory amounts,) = base.previewDepositAmounts(par);
        address[] memory assets = base.getAssets();
        for (uint256 i; i < assets.length; ++i) {
            deal(assets[i], who, IERC20Loose(assets[i]).balanceOf(who) + amounts[i]);
            vm.prank(who);
            IERC20Loose(assets[i]).approve(BASE_RESERVE, amounts[i]);
        }
        vm.prank(who);
        lp = base.deposit(par, who, 0);
    }

    function _depositBaseLpToVault(address who, uint256 lp) internal returns (uint256 shares) {
        vm.startPrank(who);
        base.approve(address(vault), lp);
        shares = vault.deposit(lp, who);
        vm.stopPrank();
    }

    function _allocate(uint256 lp) internal {
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(uint256(0)), lp);
    }

    function _deallocate(uint256 lp) internal {
        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(type(uint256).max), lp);
    }

    /// @dev Grants the pauser role to this test contract (Admin Safe has execution delay 0).
    function _grantPauser() internal {
        vm.prank(ADMIN_SAFE);
        IAccessManagerLike(ACCESS_MANAGER).grantRole(PAUSER_ROLE, address(this), 0);
    }

    // ---------------------------------------------------------------------
    // Expected values (SPEC §4, written independently of the adapter)
    // ---------------------------------------------------------------------

    /// @dev SPEC §4.1, in BaseLP units: the adapter's pro-rata claim on both legs, the native leg
    ///      converted at min(market, redemption, $1) over BaseLP's PAR value per share, less the exit
    ///      haircut, plus idle BaseLP.
    function _expectedRealAssets(uint256 nativeMark) internal view returns (uint256) {
        uint256 idle = base.balanceOf(address(adapter));
        uint256 s = meta.balanceOf(address(adapter));
        if (s == 0) return idle;
        uint256 supply = meta.totalSupply() + 1; // MetaReserve VIRTUAL_SHARES
        uint256 baseUnits = meta.netBalanceOf(BASE_RESERVE) * s / supply;
        uint256 nativeUnits = meta.netBalanceOf(native) * s / supply;
        uint256 parPerShare = base.convertToValue(1e18);
        uint256 nativeInBase =
            parPerShare == 0 ? 0 : nativeUnits * meta.nativeScale() * nativeMark / 1e18 * 1e18 / parPerShare;
        return (baseUnits + nativeInBase) * (BPS - EXIT_FEE_BPS) / BPS + idle;
    }

    /// @dev min(market, redemption, $1) of native from the live oracle, 1e18.
    function _liveNativeMark() internal view returns (uint256) {
        (uint256 p, uint256 r) = clearOracle.getPriceAndRedemptionPrice(native);
        uint256 m = p < r ? p : r;
        if (m > PAR_8) m = PAR_8;
        return m * 1e10;
    }

    /// @dev SPEC §4 stale fallback: the oracle's last stored price, min(price, redemption, $1), less
    ///      staleHaircutBps plus staleDecayBpsPerDay per day since that price was published; 0 once the
    ///      haircut reaches 100 %. Uses the adapter's own last mark when the oracle holds no price.
    function _expectedStaleMark() internal view returns (uint256) {
        (,,, uint256 r,, uint256 at, uint256 p) = clearOracle.oracleConfiguration(native);
        uint256 mark;
        if (at != 0 && p != 0) {
            uint256 m = p < r ? p : r;
            if (m > PAR_8) m = PAR_8;
            mark = m * 1e10;
        } else {
            mark = adapter.lastNativeMark();
            at = adapter.lastMarkAt();
        }
        uint256 age = block.timestamp > at ? block.timestamp - at : 0;
        uint256 haircut = (STALE_HAIRCUT_BPS * 1e18 + STALE_DECAY_BPS_PER_DAY * 1e18 * age / 1 days) / BPS;
        if (haircut >= 1e18) return 0;
        return mark * (1e18 - haircut) / 1e18;
    }

    /// @dev Value of the native leg at $1 (an upper bound on any honest mark), in BaseLP units.
    function _parBound() internal view returns (uint256) {
        uint256 idle = base.balanceOf(address(adapter));
        uint256 s = meta.balanceOf(address(adapter));
        if (s == 0) return idle;
        uint256 supply = meta.totalSupply() + 1;
        uint256 parPerShare = base.convertToValue(1e18);
        uint256 baseUnits = meta.netBalanceOf(BASE_RESERVE) * s / supply;
        uint256 nativeUnits = meta.netBalanceOf(native) * s / supply;
        return baseUnits + (parPerShare == 0 ? 0 : nativeUnits * meta.nativeScale() * 1e18 / parPerShare) + idle;
    }

    /// @dev BaseLP value on the redemption basis (USDT at 0.9992), 6 decimals, for cost checks on the zap.
    ///      The redemption basis, not par: it is what the reserve pays a single-asset exit on, so a cost
    ///      bound measured against par would charge the zap for the USDT redemption discount.
    function _baseLpToUsd6(uint256 lp) internal view returns (uint256) {
        return base.convertToRedemptionValue(lp) / 1e12;
    }
}
