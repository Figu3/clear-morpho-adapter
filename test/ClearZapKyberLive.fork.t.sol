// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {ClearForkBase, IERC20Loose} from "./ClearForkBase.sol";

/// @notice Runs the zap's balanced exit through the REAL KyberSwap router with a route from the Kyber API.
///         Two passes, both on the same fork block (FORK_BLOCK = a recent block):
///         1. without KYBER_SWAP_DATA: prints the zap address and the USDT amount to sell, then skips;
///         2. build a USDT -> USDC route for that amount with the zap as sender and recipient (Kyber
///            `/routes` then `/route/build`), and rerun with KYBER_SWAP_DATA=<calldata> and
///            KYBER_USDT_PRICE_8=<the route's implied USDT price, 8 decimals> so the oracle agrees with it.
///         Skipped in a plain `forge test`.
contract ClearZapKyberLiveForkTest is ClearForkBase {
    uint256 internal constant AMOUNT = 100_000e6;

    function test_kyberLive_balancedRedeem() public {
        if (!vm.envOr("KYBER_LIVE", false)) vm.skip(true);

        uint256 usdtPrice8 = vm.envOr("KYBER_USDT_PRICE_8", uint256(0.9988e8));
        // Gate closed (USDT more than 3 bps from 0.9992) with an oracle that agrees with the market.
        _pushPrices(PAR_8, usdtPrice8, NATIVE_ON_PEG_8);

        address user = makeAddr("kyberUser");
        deal(USDC, user, AMOUNT);
        vm.startPrank(user);
        IERC20Loose(USDC).approve(address(zap), AMOUNT);
        uint256 shares = zap.deposit(USDC, AMOUNT, user, 0, "");
        vm.stopPrank();

        uint256 sell = zap.previewBalancedRedeem(shares, USDC);
        bytes memory route = vm.envOr("KYBER_SWAP_DATA", bytes(""));
        if (route.length == 0) {
            // Pass 1: report what the route must be built for (a skipped test does not print logs).
            revert(string.concat("PREPARE zap=", vm.toString(address(zap)), " usdtToSell=", vm.toString(sell)));
        }

        uint256 lpValue = base.convertToRedemptionValue(vault.convertToAssets(shares)) / 1e12;
        vm.startPrank(user);
        vault.approve(address(zap), shares);
        uint256 out = zap.redeem(shares, USDC, user, 0, route);
        vm.stopPrank();

        console2.log("usdcOut", out);
        console2.log("lpValue", lpValue);
        assertGe(out, lpValue * (BPS - MAX_SWAP_SLIPPAGE_BPS - 5) / BPS, "Kyber exit cost too much");
        assertEq(IERC20Loose(USDT).allowance(address(zap), KYBER_ROUTER), 0, "allowance left to the router");
        assertEq(IERC20Loose(USDC).balanceOf(address(zap)), 0, "zap kept USDC");
        assertEq(IERC20Loose(USDT).balanceOf(address(zap)), 0, "zap kept USDT");
    }
}
