// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {ClearForkBase, IERC20Loose, ISwapRouter02Like} from "./ClearForkBase.sol";
import {ClearZap} from "../src/ClearZap.sol";

/// @notice SPEC §7 for the zap: USDC/USDT <-> vault shares, single-asset when the BaseReserve gate is
///         open, balanced plus a Uniswap swap when it is not.
contract ClearZapForkTest is ClearForkBase {
    uint256 internal constant AMOUNT = 100_000e6;

    address internal user = makeAddr("user");

    // =====================================================================
    // Deposit
    // =====================================================================

    function test_deposit_usdc_gateOpen_usesSingleAsset() public {
        (uint256 shares, bool single) = _zapDeposit(USDC, AMOUNT);
        assertTrue(single, "gate open but balanced path used");
        // Cost: the BaseReserve single-asset fee plus one bp of rounding/spread.
        uint256 value = _baseLpToUsd6(vault.convertToAssets(shares));
        assertGe(value, AMOUNT * (BPS - base.singleAssetFeeBps() - 1) / BPS, "single-asset deposit cost too much");
    }

    function test_deposit_usdc_gateClosed_usesBalancedAndCostBounded() public {
        _pushPoolPricesGateClosed();
        (uint256 shares, bool single) = _zapDeposit(USDC, AMOUNT);
        assertFalse(single, "gate closed but single-asset path used");
        // Cost: the USDT leg crosses the pool (slippage bound) and is credited at min(market, 0.9992).
        uint256 value = _baseLpToUsd6(vault.convertToAssets(shares));
        assertGe(value, AMOUNT * (BPS - MAX_SWAP_SLIPPAGE_BPS - 5) / BPS, "balanced deposit cost too much");
    }

    function test_deposit_usdt_gateClosed_works() public {
        _pushPoolPricesGateClosed();
        (uint256 shares, bool single) = _zapDeposit(USDT, AMOUNT);
        assertFalse(single);
        assertGt(shares, 0);
    }

    function test_deposit_revertsBelowMinShares() public {
        deal(USDC, user, AMOUNT);
        vm.startPrank(user);
        IERC20Loose(USDC).approve(address(zap), AMOUNT);
        vm.expectRevert();
        zap.deposit(USDC, AMOUNT, user, type(uint256).max, "");
        vm.stopPrank();
    }

    function test_deposit_rejectsOtherTokens() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ClearZap.UnsupportedToken.selector, USDS));
        zap.deposit(USDS, 1e18, user, 0, "");
    }

    // =====================================================================
    // Redeem (the gate-closed exit test moved here from the adapter)
    // =====================================================================

    function test_redeem_usdc_gateOpen_usesSingleAsset() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        uint256 lpValue = _baseLpToUsd6(vault.convertToAssets(shares));
        (uint256 out, bool single) = _zapRedeem(shares, USDC);
        assertTrue(single);
        assertGe(out, lpValue * (BPS - base.singleAssetFeeBps() - 1) / BPS);
    }

    function test_redeem_usdc_gateClosed_worksAndCostBounded() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        uint256 lpValue = _baseLpToUsd6(vault.convertToAssets(shares));

        _pushPoolPricesGateClosed();
        (uint256 out, bool single) = _zapRedeem(shares, USDC);
        assertFalse(single, "gate closed but single-asset path used");
        assertGe(out, lpValue * (BPS - MAX_SWAP_SLIPPAGE_BPS - 5) / BPS, "balanced exit cost too much");
    }

    function test_redeem_usdt_gateClosed_works() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        _pushPoolPricesGateClosed();
        (uint256 out,) = _zapRedeem(shares, USDT);
        assertGt(out, 0);
    }

    function test_redeem_revertsBelowMinOut() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        vm.startPrank(user);
        vault.approve(address(zap), shares);
        vm.expectRevert();
        zap.redeem(shares, USDC, user, type(uint256).max, "");
        vm.stopPrank();
    }

    function test_redeem_balanced_revertsOnManipulatedPool() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        _pushPoolPricesGateClosed();

        // Someone pushes USDT 60 bps below the oracle in the pool before the user's balanced exit.
        address attacker = makeAddr("attacker");
        uint256 dump = 400_000_000e6;
        deal(USDT, attacker, dump);
        vm.startPrank(attacker);
        IERC20Loose(USDT).approve(UNI_SWAP_ROUTER_02, dump);
        ISwapRouter02Like(UNI_SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02Like.ExactInputSingleParams(USDT, USDC, 100, attacker, dump, 0, _sqrtPriceLimitForUsdtDiscount(60))
        );
        vm.stopPrank();

        vm.startPrank(user);
        vault.approve(address(zap), shares);
        vm.expectRevert(); // the internal oracle bound fires even with minOut = 0
        zap.redeem(shares, USDC, user, 0, "");
        vm.stopPrank();
    }

    function test_redeem_requiresShareAllowance() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        vm.prank(makeAddr("thief"));
        vm.expectRevert();
        zap.redeem(shares, USDC, makeAddr("thief"), 0, "");
    }

    // =====================================================================
    // End to end and hygiene
    // =====================================================================

    function test_endToEnd_zapIn_allocate_deallocate_zapOut() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        _allocate(base.balanceOf(address(vault)) / 2);
        _deallocate(adapter.realAssets() / 2);
        (uint256 out,) = _zapRedeem(shares, USDC);
        assertGe(out, AMOUNT * (BPS - 2 * base.singleAssetFeeBps() - 30) / BPS);
    }

    function test_zapHoldsNothing_afterCalls() public {
        (uint256 shares,) = _zapDeposit(USDC, AMOUNT);
        _pushPoolPricesGateClosed();
        _zapDeposit(USDT, AMOUNT);
        _zapRedeem(shares, USDC);
        _assertZapEmpty();
    }

    // ---------------------------------------------------------------------

    function _zapDeposit(address token, uint256 amount) internal returns (uint256 shares, bool single) {
        deal(token, user, IERC20Loose(token).balanceOf(user) + amount);
        vm.startPrank(user);
        IERC20Loose(token).approve(address(zap), amount);
        vm.recordLogs();
        shares = zap.deposit(token, amount, user, 0, "");
        vm.stopPrank();
        single = _routeFromLogs(ClearZap.ZapDeposit.selector);
        _assertZapEmpty();
    }

    function _zapRedeem(uint256 shares, address token) internal returns (uint256 out, bool single) {
        vm.startPrank(user);
        vault.approve(address(zap), shares);
        uint256 before = IERC20Loose(token).balanceOf(user);
        vm.recordLogs();
        zap.redeem(shares, token, user, 0, "");
        vm.stopPrank();
        out = IERC20Loose(token).balanceOf(user) - before;
        single = _routeFromLogs(ClearZap.ZapRedeem.selector);
        _assertZapEmpty();
    }

    /// @dev The last word of the zap event's data is the `singleAsset` flag.
    function _routeFromLogs(bytes32 topic) internal returns (bool single) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(zap) && l.topics[0] == topic) {
                return abi.decode(_lastWord(l.data), (bool));
            }
        }
        revert("zap event not found");
    }

    function _lastWord(bytes memory data) internal pure returns (bytes memory w) {
        w = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            w[i] = data[data.length - 32 + i];
        }
    }

    function _assertZapEmpty() internal view {
        assertEq(IERC20Loose(USDC).balanceOf(address(zap)), 0, "zap kept USDC");
        assertEq(IERC20Loose(USDT).balanceOf(address(zap)), 0, "zap kept USDT");
        assertEq(base.balanceOf(address(zap)), 0, "zap kept BaseLP");
        assertEq(vault.balanceOf(address(zap)), 0, "zap kept vault shares");
    }

    /// @dev sqrtPriceX96 at which USDT trades `bps` below USDC (token0 USDC, token1 USDT):
    ///      sqrtP = 2^96 / sqrt(1 - bps).
    function _sqrtPriceLimitForUsdtDiscount(uint256 bps) internal pure returns (uint160) {
        uint256 oneMinus = (BPS - bps) * 1e14; // 1e18 scale
        return uint160((uint256(1) << 96) * 1e9 / _sqrt(oneMinus));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
