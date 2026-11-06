// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClearForkBase, IERC20Loose} from "./ClearForkBase.sol";
import {BaseLpUsdFeed, IChainlinkFeed} from "../src/BaseLpUsdFeed.sol";

interface IFlashLenderLike {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

interface IClearLockLike {
    function enterGlobalLock() external;
    function exitGlobalLock() external;
}

/// @notice Reads the feed from inside a Clear flash loan, when the reserve's balances are lent out.
contract FeedFlashProbe {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    BaseLpUsdFeed internal feed;
    bool public reverted;

    constructor(BaseLpUsdFeed feed_) {
        feed = feed_;
    }

    function run(address lender, address token, uint256 amount) external {
        IFlashLenderLike(lender).flashLoan(address(this), token, amount, "");
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        try feed.latestRoundData() {}
        catch {
            reverted = true;
        }
        IERC20Loose(token).approve(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

/// @notice BaseLP/USD feed against the live BaseReserve and ClearOracle. Chainlink is mocked so each test
///         controls the disagreement between the two sources.
contract BaseLpUsdFeedForkTest is ClearForkBase {
    address internal constant CHAINLINK_USDC = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant CHAINLINK_USDT = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address internal constant CLEAR_FACTORY = 0x2b2A51bbf9D3794490b9EDdA1B2B46d5aEFD0a95;

    BaseLpUsdFeed internal feed;

    function setUp() public override {
        super.setUp();
        feed = new BaseLpUsdFeed(BASE_RESERVE, CLEAR_ORACLE, CHAINLINK_USDC, CHAINLINK_USDT);
        _mockChainlink(CHAINLINK_USDC, 1e8, block.timestamp);
        _mockChainlink(CHAINLINK_USDT, 1e8, block.timestamp);
    }

    function _mockChainlink(address aggregator, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            aggregator,
            abi.encodeCall(IChainlinkFeed.latestRoundData, ()),
            abi.encode(uint80(1), answer, updatedAt, updatedAt, uint80(1))
        );
    }

    function _killChainlink(address aggregator) internal {
        vm.mockCallRevert(aggregator, abi.encodeCall(IChainlinkFeed.latestRoundData, ()), "down");
    }

    function _answer() internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer);
    }

    /// @dev The spec formula, written independently of the feed: NAV per share x net-weighted marks.
    function _expected(uint256 usdcMark8, uint256 usdtMark8) internal view returns (uint256) {
        uint256 nc = base.netBalanceOf(USDC);
        uint256 nt = base.netBalanceOf(USDT);
        (uint256 low, uint256 high) = usdcMark8 < usdtMark8 ? (usdcMark8, usdtMark8) : (usdtMark8, usdcMark8);
        // Marks further apart than the guard: the whole reserve at the lower one, so weights cannot be gamed.
        uint256 mark = low * 10_000 < high * 9975 ? low : (nc * usdcMark8 + nt * usdtMark8) / (nc + nt);
        return base.convertToValue(1e18) * mark / 1e18;
    }

    function _pushUsdt(uint256 usdt8) internal {
        _pushPrices(PAR_8, usdt8, NATIVE_ON_PEG_8);
    }

    // ---- Normal operation ----

    function test_atPeg_followsClearMarks() public {
        _pushUsdt(USDT_AT_PAR_8);
        // USDT capped by its 0.9992 redemption price, same as Clear's conservative price.
        assertEq(_answer(), _expected(PAR_8, USDT_REDEMPTION_8));
    }

    function test_clearDepeg_lowersPrice_whileChainlinkLags() public {
        _pushUsdt(0.998e8);
        assertEq(_answer(), _expected(PAR_8, 0.998e8));
    }

    function test_chainlinkBeyondGuard_wins() public {
        _pushUsdt(USDT_AT_PAR_8);
        _mockChainlink(CHAINLINK_USDT, 0.99e8, block.timestamp);
        assertEq(_answer(), _expected(PAR_8, 0.99e8));
    }

    function test_chainlinkWithinGuard_isIgnored() public {
        _pushUsdt(USDT_AT_PAR_8);
        _mockChainlink(CHAINLINK_USDT, 0.997e8, block.timestamp);
        assertEq(_answer(), _expected(PAR_8, USDT_REDEMPTION_8));
    }

    function test_guardBoundary_isMeasuredFromTheCappedMark() public {
        _pushUsdt(USDT_AT_PAR_8);
        uint256 threshold = USDT_REDEMPTION_8 * 9975 / 10_000;

        _mockChainlink(CHAINLINK_USDT, int256(threshold), block.timestamp);
        assertEq(_answer(), _expected(PAR_8, USDT_REDEMPTION_8), "exactly 25 bps is within the guard");

        _mockChainlink(CHAINLINK_USDT, int256(threshold - 1), block.timestamp);
        assertEq(_answer(), _expected(PAR_8, threshold - 1), "past 25 bps Chainlink takes over");
    }

    function testFuzz_markNeverMoreThanGuardAboveChainlink(uint256 usdt8, int256 chainlinkUsdt) public {
        usdt8 = bound(usdt8, 0.96e8, 1.01e8);
        chainlinkUsdt = bound(chainlinkUsdt, 0.9e8, 1.05e8);
        _pushUsdt(usdt8);
        _mockChainlink(CHAINLINK_USDT, chainlinkUsdt, block.timestamp);
        uint256 ceiling = uint256(chainlinkUsdt) * 10_000 / 9975 + 1;
        if (ceiling < USDT_REDEMPTION_8) {
            assertLe(_answer(), _expected(PAR_8, ceiling) + 1);
        }
    }

    function test_neverAboveNavPerShare_whenSourcesAbovePar() public {
        _pushPrices(1.002e8, 1.002e8, NATIVE_ON_PEG_8);
        _mockChainlink(CHAINLINK_USDC, 1.002e8, block.timestamp);
        _mockChainlink(CHAINLINK_USDT, 1.002e8, block.timestamp);
        assertEq(_answer(), _expected(PAR_8, USDT_REDEMPTION_8));
    }

    function testFuzz_neverAboveNavPerShare(uint256 usdt8, int256 chainlinkUsdt) public {
        usdt8 = bound(usdt8, 0.96e8, 1.01e8);
        chainlinkUsdt = bound(chainlinkUsdt, 0.9e8, 1.05e8);
        _pushUsdt(usdt8);
        _mockChainlink(CHAINLINK_USDT, chainlinkUsdt, block.timestamp);
        assertLe(_answer() * 1e10, base.convertToValue(1e18));
    }

    function test_donation_doesNotMovePrice() public {
        uint256 before = _answer();
        deal(USDC, address(this), 1_000_000e6);
        IERC20Loose(USDC).transfer(BASE_RESERVE, 1_000_000e6);
        assertEq(_answer(), before);
    }

    // ---- Spot weights ----

    function _mockNet(address asset, uint256 amount) internal {
        vm.mockCall(BASE_RESERVE, abi.encodeCall(base.netBalanceOf, (asset)), abi.encode(amount));
    }

    function test_wideGap_compositionShiftDoesNotMovePrice() public {
        _pushUsdt(0.99e8);
        uint256 before = _answer();
        assertEq(before, base.convertToValue(1e18) * 0.99e8 / 1e18);
        _mockNet(USDC, 1_000_000e6);
        _mockNet(USDT, 1e6);
        assertEq(_answer(), before);
    }

    function test_narrowGap_staysWeighted() public {
        _pushUsdt(0.998e8);
        _mockNet(USDC, 1_000_000e6);
        _mockNet(USDT, 1_000_000e6);
        assertEq(_answer(), base.convertToValue(1e18) * 0.999e8 / 1e18);
    }

    // ---- Chainlink age ----

    function test_staleChainlink_cannotOverrideFreshClear() public {
        _pushUsdt(USDT_AT_PAR_8);
        _mockChainlink(CHAINLINK_USDT, 0.99e8, block.timestamp - 25 hours - 1);
        assertEq(_answer(), _expected(PAR_8, USDT_REDEMPTION_8));
    }

    function test_chainlinkAtMaxAge_stillGuards() public {
        _pushUsdt(USDT_AT_PAR_8);
        _mockChainlink(CHAINLINK_USDT, 0.99e8, block.timestamp - 25 hours);
        assertEq(_answer(), _expected(PAR_8, 0.99e8));
    }

    function test_staleChainlink_stillUsedWhenClearStale() public {
        _makeOracleStale();
        _mockChainlink(CHAINLINK_USDT, 0.995e8, block.timestamp - 3 days);
        assertEq(_answer(), _expected(PAR_8, 0.995e8));
    }

    // ---- Degraded sources: the feed keeps answering ----

    function test_keeperStalled_fallsBackToChainlink() public {
        _pushUsdt(0.97e8); // a low price that goes stale must not stick
        _makeOracleStale();
        _mockChainlink(CHAINLINK_USDT, 0.995e8, block.timestamp);
        assertEq(_answer(), _expected(PAR_8, 0.995e8));
    }

    function test_keeperStalled_redemptionCapStillApplies() public {
        _makeOracleStale();
        assertEq(_answer(), _expected(PAR_8, USDT_REDEMPTION_8));
    }

    function test_priceInvalidated_fallsBackToChainlink() public {
        vm.prank(PYTH_ORACLE_ADAPTER);
        clearOracle.invalidatePrice(USDT);
        _mockChainlink(CHAINLINK_USDT, 0.995e8, block.timestamp);
        assertEq(_answer(), _expected(PAR_8, 0.995e8));
    }

    function test_chainlinkDown_usesFreshClear() public {
        _pushUsdt(0.998e8);
        _killChainlink(CHAINLINK_USDT);
        assertEq(_answer(), _expected(PAR_8, 0.998e8));
    }

    function test_chainlinkNonPositive_usesFreshClear() public {
        _pushUsdt(0.998e8);
        _mockChainlink(CHAINLINK_USDT, 0, block.timestamp);
        assertEq(_answer(), _expected(PAR_8, 0.998e8));
    }

    function test_noSourceForAnAsset_reverts() public {
        _makeOracleStale();
        _killChainlink(CHAINLINK_USDT);
        vm.expectRevert(abi.encodeWithSelector(BaseLpUsdFeed.NoPrice.selector, USDT));
        feed.latestRoundData();
    }

    function test_reservePaused_stillPrices() public {
        _grantPauser();
        base.pause();
        assertGt(_answer(), 0);
    }

    // ---- Manipulation ----

    function test_flashLoan_refusesToPrice() public {
        FeedFlashProbe probe = new FeedFlashProbe(feed);
        deal(USDC, address(probe), 1_000_000e6); // covers the fee
        probe.run(BASE_RESERVE, USDC, 1_000_000e6);
        assertTrue(probe.reverted(), "feed priced a reserve with its balances lent out");
    }

    function test_clearLockHeld_refusesToPrice() public {
        IClearLockLike(CLEAR_FACTORY).enterGlobalLock();
        vm.expectRevert(BaseLpUsdFeed.ClearCallInProgress.selector);
        feed.latestRoundData();
    }

    // ---- Interface ----

    function test_interface() public view {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "Clear BaseLP / USD");
    }

    function test_updatedAt_isOldestSourceUsed() public {
        _makeOracleStale();
        uint256 old = block.timestamp - 5 hours;
        _mockChainlink(CHAINLINK_USDC, 1e8, old);
        (,, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, old);
        assertEq(startedAt, old);
    }

    function test_updatedAt_ignoresChainlinkWithinGuard() public {
        _pushUsdt(USDT_AT_PAR_8);
        _mockChainlink(CHAINLINK_USDC, 1e8, block.timestamp - 5 hours);
        _mockChainlink(CHAINLINK_USDT, 1e8, block.timestamp - 5 hours);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(updatedAt, block.timestamp - 5 hours);
    }

    function test_constructor_rejectsWrongDecimals() public {
        vm.mockCall(CHAINLINK_USDT, abi.encodeCall(IChainlinkFeed.decimals, ()), abi.encode(uint8(18)));
        vm.expectRevert(BaseLpUsdFeed.BadDecimals.selector);
        new BaseLpUsdFeed(BASE_RESERVE, CLEAR_ORACLE, CHAINLINK_USDC, CHAINLINK_USDT);
    }
}
