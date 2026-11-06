// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {BaseLpUsdFeed} from "../src/BaseLpUsdFeed.sol";
import {IClearBaseReserve, IClearOracle} from "../src/interfaces/IClear.sol";

interface IChainlinkRounds {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IMorphoOracleFactory {
    function createMorphoChainlinkOracleV2(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 salt
    ) external returns (address oracle);
}

interface IMorphoOracle {
    function price() external view returns (uint256);
}

/// @notice The feed on the latest mainnet block with nothing mocked: real Chainlink, ClearOracle and reserve.
/// @dev    Manual, as the state moves: FEED_LIVE=true ETH_RPC_URL=<rpc> forge test --match-contract BaseLpUsdFeedLive -vv
contract BaseLpUsdFeedLiveTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant BASE_RESERVE = 0xd1b4d7F6f651c13b687A22fC97B718AAD3A0E41D;
    address internal constant CLEAR_ORACLE = 0x323F9737f4A2763FA419bD679ce0D7a2bc322a30;
    address internal constant CHAINLINK_USDC = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant CHAINLINK_USDT = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address internal constant MORPHO_ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;

    BaseLpUsdFeed internal feed;
    IClearBaseReserve internal base = IClearBaseReserve(BASE_RESERVE);
    IClearOracle internal oracle = IClearOracle(CLEAR_ORACLE);

    function setUp() public {
        if (!vm.envOr("FEED_LIVE", false)) vm.skip(true);
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        feed = new BaseLpUsdFeed(BASE_RESERVE, CLEAR_ORACLE, CHAINLINK_USDC, CHAINLINK_USDT);
    }

    function _log(string memory name, address asset, address chainlink) internal view {
        (,,, uint256 redemption, uint256 ttl, uint256 clearAt, uint256 clearPrice) = oracle.oracleConfiguration(asset);
        (, int256 answer,, uint256 at,) = IChainlinkRounds(chainlink).latestRoundData();
        console2.log(name);
        console2.log("  clear price, age s, ttl s", clearPrice, block.timestamp - clearAt, ttl);
        console2.log("  redemption", redemption);
        console2.log("  chainlink price, age s", uint256(answer), block.timestamp - at);
        console2.log("  net balance", base.netBalanceOf(asset));
    }

    function test_live_pricesRealState() public view {
        console2.log("block", block.number);
        _log("USDC", USDC, CHAINLINK_USDC);
        _log("USDT", USDT, CHAINLINK_USDT);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        uint256 nav = base.convertToValue(1e18);
        console2.log("NAV per share (18)", nav);
        console2.log("feed answer (8)", uint256(answer));
        console2.log("feed age s", block.timestamp - updatedAt);
        console2.log("reserve value, supply", base.totalReserveValue(), base.totalSupply());

        assertGt(answer, 0);
        assertLe(uint256(answer) * 1e10, nav, "above NAV per share");
        assertGe(uint256(answer) * 1e10, nav * 99 / 100, "over 1% below NAV per share with no depeg");
    }

    /// @dev Checks the 24 hour heartbeat CHAINLINK_MAX_AGE assumes, from the feeds' own recent rounds.
    function test_live_chainlinkHeartbeatFitsMaxAge() public view {
        _assertHeartbeat("USDC", CHAINLINK_USDC);
        _assertHeartbeat("USDT", CHAINLINK_USDT);
    }

    function _assertHeartbeat(string memory name, address chainlink) internal view {
        (uint80 id,,, uint256 at,) = IChainlinkRounds(chainlink).latestRoundData();
        uint256 maxGap = block.timestamp - at;
        uint256 rounds;
        for (uint256 i; i < 30; ++i) {
            try IChainlinkRounds(chainlink).getRoundData(id - 1) returns (uint80, int256, uint256, uint256 prev, uint80) {
                if (prev == 0) break;
                if (at - prev > maxGap) maxGap = at - prev;
                at = prev;
                --id;
                ++rounds;
            } catch {
                break;
            }
        }
        console2.log(name, "rounds, max gap s", rounds, maxGap);
        assertGt(rounds, 0);
        assertLe(maxGap, feed.CHAINLINK_MAX_AGE(), "heartbeat exceeds CHAINLINK_MAX_AGE");
    }

    /// @dev BaseLP (18 decimals) quoted in USDC (6 decimals) through Morpho's own oracle.
    function test_live_morphoOracleReadsFeed() public {
        if (MORPHO_ORACLE_FACTORY.code.length == 0) {
            console2.log("no Morpho oracle factory at this address");
            vm.skip(true);
        }
        address morphoOracle = IMorphoOracleFactory(MORPHO_ORACLE_FACTORY).createMorphoChainlinkOracleV2(
            address(0), 1, address(feed), address(0), 18, address(0), 1, CHAINLINK_USDC, address(0), 6, bytes32("clear")
        );
        uint256 price = IMorphoOracle(morphoOracle).price();
        (, int256 answer,,,) = feed.latestRoundData();
        (, int256 usdc,,,) = IChainlinkRounds(CHAINLINK_USDC).latestRoundData();
        console2.log("morpho price (scale 1e24 = $1 per BaseLP)", price);
        assertApproxEqRel(price, uint256(answer) * 1e24 / uint256(usdc), 1e12);
    }
}
