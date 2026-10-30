// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {VaultV2} from "vault-v2/VaultV2.sol";

import {ClearForkBase, IERC20Loose} from "./ClearForkBase.sol";
import {ClearMetaReserveAdapter} from "../src/ClearMetaReserveAdapter.sol";
import {ClearZap} from "../src/ClearZap.sol";
import {IClearMetaReserve, IClearOracle} from "../src/interfaces/IClear.sol";

/// @notice Drives the vault, adapter, zap, oracle and MetaReserve through random sequences. Calls that
///         revert for legitimate reasons (gate closed, nothing to withdraw) are swallowed: the
///         invariants are about what must hold whatever the sequence.
contract ClearHandler is CommonBase, StdCheats, StdUtils {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant PYTH_ORACLE_ADAPTER = 0x39b548E590eC3B6333a200fa715F9eAb04F76858;

    VaultV2 internal vault;
    ClearMetaReserveAdapter internal adapter;
    ClearZap internal zap;
    IClearMetaReserve internal meta;
    IClearOracle internal oracle;
    address internal allocator;
    address internal user = address(0xBEEF);

    uint256 public allocations;
    uint256 public zapDeposits;

    constructor(VaultV2 vault_, ClearMetaReserveAdapter adapter_, ClearZap zap_, address allocator_) {
        vault = vault_;
        adapter = adapter_;
        zap = zap_;
        meta = adapter_.metaReserve();
        oracle = adapter_.oracle();
        allocator = allocator_;
    }

    function allocate(uint256 lp) external {
        uint256 idle = IERC20Loose(vault.asset()).balanceOf(address(vault));
        if (idle < 2e18) return;
        lp = bound(lp, 1e18, idle);
        vm.prank(allocator);
        try vault.allocate(address(adapter), abi.encode(uint256(0)), lp) {
            ++allocations;
        } catch {}
    }

    function deallocate(uint256 lp) external {
        uint256 position = vault.allocation(adapter.adapterId());
        if (position < 2e18) return;
        lp = bound(lp, 1e18, position / 2);
        vm.prank(allocator);
        try vault.deallocate(address(adapter), abi.encode(type(uint256).max), lp) {} catch {}
    }

    /// @dev USDT and USDS from 60 bps under to 10 bps over par. Gate open only in a narrow band.
    function movePrices(uint256 usdtBps, uint256 usdsBps) external {
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = USDT;
        assets[2] = USDS;
        uint256[] memory prices = new uint256[](3);
        prices[0] = 1e8;
        prices[1] = 1e8 - 0.006e8 + bound(usdtBps, 0, 70) * 1e4;
        prices[2] = 1e8 - 0.006e8 + bound(usdsBps, 0, 70) * 1e4;
        _push(assets, prices);
    }

    /// @dev Gate-open prices, so the gated paths get exercised too.
    function openGate() external {
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = USDT;
        assets[2] = USDS;
        uint256[] memory prices = new uint256[](3);
        prices[0] = 1e8;
        prices[1] = 0.9992e8;
        prices[2] = 0.9999e8;
        _push(assets, prices);
    }

    /// @dev Up to 3 hours: crosses the 1 h oracle TTL often.
    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 hours));
    }

    function metaDepegSwap(uint256 amount) external {
        amount = bound(amount, 1_000e18, 50_000e18);
        deal(USDS, user, amount);
        vm.startPrank(user);
        IERC20Loose(USDS).approve(address(meta), amount);
        try meta.swap(USDS, meta.baseReserve(), amount, 0, 0, user) {} catch {}
        vm.stopPrank();
    }

    function zapDeposit(bool usdt, uint256 amount) external {
        address token = usdt ? USDT : USDC;
        amount = bound(amount, 1_000e6, 200_000e6);
        deal(token, user, amount);
        vm.startPrank(user);
        IERC20Loose(token).approve(address(zap), amount);
        try zap.deposit(token, amount, user, 0, "") {
            ++zapDeposits;
        } catch {}
        vm.stopPrank();
    }

    function zapRedeem(bool usdt, uint256 shares) external {
        uint256 held = vault.balanceOf(user);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.startPrank(user);
        vault.approve(address(zap), shares);
        try zap.redeem(shares, usdt ? USDT : USDC, user, 0, "") {} catch {}
        vm.stopPrank();
    }

    function poke() external {
        try adapter.poke() {} catch {}
    }

    function _push(address[] memory assets, uint256[] memory prices) internal {
        vm.warp(block.timestamp + 1);
        uint256[] memory times = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            times[i] = block.timestamp;
        }
        vm.prank(PYTH_ORACLE_ADAPTER);
        oracle.updateCustomOraclePrices(assets, prices, times);
    }
}

contract ClearInvariantTest is ClearForkBase {
    ClearHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ClearHandler(vault, adapter, zap, allocator);
        // Every run starts with a live position, so no sequence checks an empty adapter.
        _allocate(400_000e18);
        targetContract(address(handler));
    }

    /// @dev The handler really drives each path (guards against invariants passing on swallowed reverts).
    function test_handler_exercisesEveryPath() public {
        handler.openGate();
        handler.allocate(100_000e18);
        handler.zapDeposit(false, 50_000e6);
        handler.zapDeposit(true, 50_000e6);
        handler.deallocate(50_000e18);
        assertEq(handler.allocations(), 1, "allocate swallowed a revert");
        assertEq(handler.zapDeposits(), 2, "zapDeposit swallowed a revert");
        assertGt(vault.balanceOf(address(0xBEEF)), 0);
    }

    /// @dev §7.1 Morpho liveness: an adapter whose realAssets reverts bricks the whole vault.
    function invariant_realAssetsNeverReverts() public view {
        try adapter.realAssets() {}
        catch {
            revert("realAssets reverted");
        }
    }

    function invariant_vaultAccrualNeverReverts() public view {
        try vault.accrueInterestView() {}
        catch {
            revert("accrueInterestView reverted");
        }
    }

    /// @dev §7.2 Never valued above the pro-rata claim with the native leg at $1.
    function invariant_realAssetsNotAbovePar() public view {
        assertLe(adapter.realAssets(), _parBound());
    }

    /// @dev The zap never keeps anything between calls.
    function invariant_zapHoldsNothing() public view {
        assertEq(IERC20Loose(USDC).balanceOf(address(zap)), 0);
        assertEq(IERC20Loose(USDT).balanceOf(address(zap)), 0);
        assertEq(base.balanceOf(address(zap)), 0);
        assertEq(vault.balanceOf(address(zap)), 0);
    }
}
