// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {ClearForkBase, IERC20Loose} from "./ClearForkBase.sol";
import {ClearZap} from "../src/ClearZap.sol";

/// @notice Stand-in for an aggregator router: executes whatever route the caller encodes. `swap` pulls
///         `sellAmount` from the caller (the zap) and pays `buyAmount` from its own inventory to `to`, so a test
///         can encode a fair route, a bad rate, an over-pull, a wrong recipient or a re-entry.
contract MockAggregator {
    function swap(address sell, address buy, uint256 sellAmount, uint256 buyAmount, address to) external {
        IERC20Loose(sell).transferFrom(msg.sender, address(this), sellAmount);
        IERC20Loose(buy).transfer(to, buyAmount);
    }

    function reenterDeposit(ClearZap zap, address token, uint256 amount) external {
        zap.deposit(token, amount, address(this), 0, "");
    }
}

/// @notice The zap's balanced path through an aggregator route (`swapData`), against the live reserves on a
///         fork. The aggregator is a mock so each route outcome can be forced; the Kyber router itself is only
///         called with real calldata in {ClearZapKyberLiveForkTest}.
contract ClearZapAggregatorForkTest is ClearForkBase {
    uint256 internal constant AMOUNT = 100_000e6;

    MockAggregator internal agg;
    ClearZap internal aggZap;
    address internal user = makeAddr("aggUser");

    function setUp() public override {
        super.setUp();
        agg = new MockAggregator();
        aggZap = new ClearZap(address(vault), CLEAR_ORACLE, UNI_USDC_USDT_100, address(agg), MAX_SWAP_SLIPPAGE_BPS);
        deal(USDC, address(agg), 10_000_000e6);
        deal(USDT, address(agg), 10_000_000e6);
        _pushPoolPricesGateClosed();
    }

    // =====================================================================
    // Deposit
    // =====================================================================

    function test_deposit_viaAggregator_fairRoute() public {
        (uint256 maxSell, uint256 need) = aggZap.previewBalancedDeposit(USDC, AMOUNT);
        bytes memory route = _route(USDC, USDT, _fairCost(need), need, address(aggZap));
        assertLe(_fairCost(need), maxSell);

        (uint256 shares, bool via) = _deposit(USDC, AMOUNT, route);
        assertTrue(via, "aggregator path not reported");
        uint256 value = base.convertToRedemptionValue(vault.convertToAssets(shares)) / 1e12;
        assertGe(value, AMOUNT * (BPS - MAX_SWAP_SLIPPAGE_BPS - 5) / BPS, "aggregator deposit cost too much");
        assertEq(IERC20Loose(USDC).allowance(address(aggZap), address(agg)), 0, "allowance left to the aggregator");
        _assertEmpty();
    }

    /// @dev Re-audit finding (zap) 1: the documented recipe, a route selling exactly `maxSell`, must not leave
    ///      the zap short of the tokenIn leg the reserve pulls next. Fuzzed over amounts, both directions.
    function testFuzz_deposit_viaAggregator_sellingFullMaxSell(uint256 amount, bool usdtIn) public {
        amount = bound(amount, 1_000e6, 2_000_000e6);
        (address tokenIn, address other) = usdtIn ? (USDT, USDC) : (USDC, USDT);
        (uint256 maxSell, uint256 need) = aggZap.previewBalancedDeposit(tokenIn, amount);
        bytes memory route = _route(tokenIn, other, maxSell, need, address(aggZap));
        (uint256 shares, bool via) = _deposit(tokenIn, amount, route);
        assertTrue(via);
        assertGt(shares, 0);
        _assertEmpty();
    }

    /// @dev Re-audit finding (zap) AMM-1: a route that leaves the other leg unsold must revert, not hand the
    ///      caller a USDC/USDT mix while reporting a single-token exit.
    function test_redeem_viaAggregator_revertsWhenLegLeftUnsold() public {
        (uint256 shares,) = _deposit(USDC, AMOUNT, "");
        uint256 sell = aggZap.previewBalancedRedeem(shares, USDC);
        bytes memory route = _route(USDT, USDC, sell / 2, _fairProceeds(sell / 2), address(aggZap));

        vm.startPrank(user);
        vault.approve(address(aggZap), shares);
        vm.expectPartialRevert(ClearZap.UnsoldLeg.selector);
        aggZap.redeem(shares, USDC, user, 0, route);
        vm.stopPrank();
    }

    function test_constructor_rejectsAggregatorWithoutCode() public {
        // Not makeAddr("eoa"): that well-known test key carries an EIP-7702 delegation (23 bytes) on mainnet.
        address eoa = address(uint160(uint256(keccak256("clear-zap/aggregator-without-code"))));
        assertEq(eoa.code.length, 0);
        vm.expectRevert(ClearZap.InvalidParameters.selector);
        new ClearZap(address(vault), CLEAR_ORACLE, UNI_USDC_USDT_100, eoa, MAX_SWAP_SLIPPAGE_BPS);
    }

    function test_deposit_viaAggregator_revertsOnBadRate() public {
        (, uint256 need) = aggZap.previewBalancedDeposit(USDC, AMOUNT);
        bytes memory route = _route(USDC, USDT, _fairCost(need), need - 1, address(aggZap));
        _expectDepositRevert(USDC, AMOUNT, route, ClearZap.SlippageExceeded.selector);
    }

    function test_deposit_viaAggregator_cannotPullMoreThanBound() public {
        (uint256 maxSell, uint256 need) = aggZap.previewBalancedDeposit(USDC, AMOUNT);
        bytes memory route = _route(USDC, USDT, maxSell + 1, need, address(aggZap));
        // The exact allowance makes the router's pull fail, which surfaces as a failed aggregator call.
        _expectDepositRevert(USDC, AMOUNT, route, ClearZap.AggregatorCallFailed.selector);
    }

    function test_deposit_viaAggregator_revertsOnWrongRecipient() public {
        (, uint256 need) = aggZap.previewBalancedDeposit(USDC, AMOUNT);
        bytes memory route = _route(USDC, USDT, _fairCost(need), need, makeAddr("elsewhere"));
        _expectDepositRevert(USDC, AMOUNT, route, ClearZap.SlippageExceeded.selector);
    }

    function test_deposit_viaAggregator_blocksReentry() public {
        bytes memory route = abi.encodeCall(MockAggregator.reenterDeposit, (aggZap, USDC, 1e6));
        // The inner zap.deposit reverts Reentrancy, which the outer call reports as a failed aggregator call.
        _expectDepositRevert(USDC, AMOUNT, route, ClearZap.AggregatorCallFailed.selector);
    }

    function test_deposit_swapDataIgnored_whenGateOpen() public {
        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_ON_PEG_8);
        (uint256 shares, bool via) = _deposit(USDC, AMOUNT, hex"deadbeef");
        assertFalse(via);
        assertGt(shares, 0);
    }

    // =====================================================================
    // Redeem
    // =====================================================================

    function test_redeem_viaAggregator_fairRoute() public {
        (uint256 shares,) = _deposit(USDC, AMOUNT, "");
        uint256 lpValue = base.convertToRedemptionValue(vault.convertToAssets(shares)) / 1e12;

        uint256 sell = aggZap.previewBalancedRedeem(shares, USDC);
        bytes memory route = _route(USDT, USDC, sell, _fairProceeds(sell), address(aggZap));
        uint256 out = _redeem(shares, USDC, route);

        assertGe(out, lpValue * (BPS - MAX_SWAP_SLIPPAGE_BPS - 5) / BPS, "aggregator exit cost too much");
        assertEq(IERC20Loose(USDT).allowance(address(aggZap), address(agg)), 0, "allowance left to the aggregator");
        _assertEmpty();
    }

    function test_redeem_viaAggregator_revertsOnBadRate() public {
        (uint256 shares,) = _deposit(USDC, AMOUNT, "");
        uint256 sell = aggZap.previewBalancedRedeem(shares, USDC);
        // 60 bps under the oracle cross-rate, beyond the 5 bps bound.
        bytes memory route = _route(USDT, USDC, sell, _fairProceeds(sell) * (BPS - 60) / BPS, address(aggZap));

        vm.startPrank(user);
        vault.approve(address(aggZap), shares);
        vm.expectPartialRevert(ClearZap.SlippageExceeded.selector);
        aggZap.redeem(shares, USDC, user, 0, route);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------

    function _route(address sell, address buy, uint256 sellAmount, uint256 buyAmount, address to)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(MockAggregator.swap, (sell, buy, sellAmount, buyAmount, to));
    }

    /// @dev USDC cost of `usdtOut` at the oracle's USDT price, rounded up.
    function _fairCost(uint256 usdtOut) internal view returns (uint256) {
        (uint256 pt,) = clearOracle.getPriceAndRedemptionPrice(USDT);
        (uint256 pc,) = clearOracle.getPriceAndRedemptionPrice(USDC);
        return (usdtOut * pt + pc - 1) / pc;
    }

    /// @dev USDC proceeds of selling `usdtIn` at the oracle's USDT price, rounded down.
    function _fairProceeds(uint256 usdtIn) internal view returns (uint256) {
        (uint256 pt,) = clearOracle.getPriceAndRedemptionPrice(USDT);
        (uint256 pc,) = clearOracle.getPriceAndRedemptionPrice(USDC);
        return usdtIn * pt / pc;
    }

    function _deposit(address token, uint256 amount, bytes memory route) internal returns (uint256 shares, bool via) {
        deal(token, user, IERC20Loose(token).balanceOf(user) + amount);
        vm.startPrank(user);
        IERC20Loose(token).approve(address(aggZap), amount);
        vm.recordLogs();
        shares = aggZap.deposit(token, amount, user, 0, route);
        vm.stopPrank();
        via = _viaFromLogs(ClearZap.ZapDeposit.selector);
    }

    function _redeem(uint256 shares, address token, bytes memory route) internal returns (uint256 out) {
        vm.startPrank(user);
        vault.approve(address(aggZap), shares);
        uint256 before = IERC20Loose(token).balanceOf(user);
        aggZap.redeem(shares, token, user, 0, route);
        vm.stopPrank();
        out = IERC20Loose(token).balanceOf(user) - before;
    }

    /// @dev `selector` is matched on the revert's first four bytes (arguments vary with live state).
    function _expectDepositRevert(address token, uint256 amount, bytes memory route, bytes4 selector) internal {
        deal(token, user, amount);
        vm.startPrank(user);
        IERC20Loose(token).approve(address(aggZap), amount);
        vm.expectPartialRevert(selector);
        aggZap.deposit(token, amount, user, 0, route);
        vm.stopPrank();
    }

    /// @dev `viaAggregator` is the second-to-last word of the zap event's data.
    function _viaFromLogs(bytes32 topic) internal returns (bool via) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(aggZap) && l.topics[0] == topic) {
                (,,, bool v,) = abi.decode(l.data, (uint256, uint256, uint256, bool, bool));
                return v;
            }
        }
        revert("zap event not found");
    }

    function _assertEmpty() internal view {
        assertEq(IERC20Loose(USDC).balanceOf(address(aggZap)), 0, "zap kept USDC");
        assertEq(IERC20Loose(USDT).balanceOf(address(aggZap)), 0, "zap kept USDT");
        assertEq(base.balanceOf(address(aggZap)), 0, "zap kept BaseLP");
    }
}
