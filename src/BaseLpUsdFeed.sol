// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClearBaseReserve, IClearFactoryLock, IClearOracle} from "./interfaces/IClear.sol";

/// @notice Subset of Chainlink's AggregatorV3Interface.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IHasDecimals {
    function decimals() external view returns (uint8);
}

interface IHasClearFactory {
    function factory() external view returns (address);
}

/// @title BaseLpUsdFeed
/// @notice BaseLP/USD price for external consumers (lending markets), behind a Chainlink-style interface so
///         it plugs into Morpho's `MorphoChainlinkOracleV2` as a base feed.
///
///             answer = NAV per share x net-balance-weighted mark
///             cap_i  = min(redemption price, $1)
///             mark_i = min(ClearOracle price, cap_i)   if ClearOracle is fresh
///                      min(Chainlink price, cap_i)     if Chainlink is over 25 bps below that, or
///                                                      ClearOracle is stale
///
///         ClearOracle is the primary source, so the feed agrees with the prices Clear trades on. Chainlink
///         is the backup when the keeper stalls, and a guard against a bad or outdated Clear price while
///         the feed backs leveraged lending positions. Inside the guard band it is ignored, so its lag cannot
///         liquidate anyone.
/// @dev    Stateless and read-only. Reverts in two cases only:
///         - {ClearCallInProgress}: the Clear factory lock is held, which includes the callback of a Clear
///           flash loan. The reserve's balances are lent out then and NAV moves by the borrowed amount. The
///           lock is transient, so this only blocks the transaction holding it.
///         - {NoPrice}: an asset has neither a fresh ClearOracle price nor a usable Chainlink answer.
///         A stale Chainlink answer is still used, like Morpho's own oracles do; {latestRoundData} reports
///         its age through `updatedAt` so consumers can apply their own bound.
contract BaseLpUsdFeed is IChainlinkFeed {
    uint8 public constant decimals = 8;
    uint256 public constant version = 1;
    string public constant description = "Clear BaseLP / USD";

    uint256 internal constant PAR = 1e8;
    uint256 internal constant BPS = 10_000;
    /// @dev Equal to the 25 bps deviation threshold of Chainlink's stablecoin feeds, so ordinary Chainlink lag
    ///      should not move the mark. There is no margin: a lag slightly past the threshold can.
    uint256 public constant CHAINLINK_GUARD_BPS = 25;

    IClearBaseReserve public immutable baseReserve;
    IClearOracle public immutable oracle;
    IClearFactoryLock public immutable clearFactory;
    address public immutable asset0;
    address public immutable asset1;
    IChainlinkFeed public immutable chainlink0;
    IChainlinkFeed public immutable chainlink1;

    error ClearCallInProgress();
    error NoPrice(address asset);
    error BadDecimals();
    error BadAssets();

    /// @param chainlink0_ Chainlink USD feed of the reserve's first asset, in {IClearBaseReserve.getAssets} order.
    /// @param chainlink1_ Same for the second asset.
    constructor(address baseReserve_, address oracle_, address chainlink0_, address chainlink1_) {
        address[] memory assets = IClearBaseReserve(baseReserve_).getAssets();
        // Net balances are weighted in native units, so both assets must share their decimals.
        if (assets.length != 2) revert BadAssets();
        if (IHasDecimals(assets[0]).decimals() != IHasDecimals(assets[1]).decimals()) revert BadAssets();
        if (IChainlinkFeed(chainlink0_).decimals() != decimals) revert BadDecimals();
        if (IChainlinkFeed(chainlink1_).decimals() != decimals) revert BadDecimals();
        for (uint256 i; i < 2; ++i) {
            (,, uint8 oracleDecimals,,,,) = IClearOracle(oracle_).oracleConfiguration(assets[i]);
            if (oracleDecimals != decimals) revert BadDecimals();
        }

        baseReserve = IClearBaseReserve(baseReserve_);
        oracle = IClearOracle(oracle_);
        clearFactory = IClearFactoryLock(IHasClearFactory(baseReserve_).factory());
        asset0 = assets[0];
        asset1 = assets[1];
        chainlink0 = IChainlinkFeed(chainlink0_);
        chainlink1 = IChainlinkFeed(chainlink1_);
    }

    /// @notice Latest BaseLP/USD price, 8 decimals. `updatedAt` is the older timestamp of the two sources that
    ///         set the asset marks; there are no rounds, so the round fields are zero.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (clearFactory.globalLockHolder() != address(0)) revert ClearCallInProgress();

        (uint256 mark0, uint256 at0) = _mark(asset0, chainlink0);
        (uint256 mark1, uint256 at1) = _mark(asset1, chainlink1);

        uint256 net0 = baseReserve.netBalanceOf(asset0);
        uint256 net1 = baseReserve.netBalanceOf(asset1);
        uint256 mark = _weightedMark(mark0, mark1, net0, net1);

        uint256 answer = baseReserve.convertToValue(1e18) * mark / 1e18;
        uint256 updatedAt = at0 < at1 ? at0 : at1;
        return (0, int256(answer), updatedAt, updatedAt, 0);
    }

    function _weightedMark(uint256 mark0, uint256 mark1, uint256 net0, uint256 net1) internal pure returns (uint256) {
        // Fully encumbered reserve: no composition to weight, take the worse mark.
        if (net0 + net1 == 0) return mark0 < mark1 ? mark0 : mark1;
        return (net0 * mark0 + net1 * mark1) / (net0 + net1);
    }

    /// @dev The capped Clear price, unless Chainlink is missing it by more than the guard; see the contract
    ///      notice. `at` is the timestamp of the source that set the mark.
    function _mark(address asset, IChainlinkFeed chainlink) internal view returns (uint256 mark, uint256 at) {
        // oracleConfiguration does not check freshness, so unlike getPriceAndRedemptionPrice it cannot revert.
        (,,, uint256 redemption, uint256 ttl, uint256 clearAt, uint256 clearPrice) = oracle.oracleConfiguration(asset);
        bool clearFresh = clearPrice != 0 && clearAt + ttl >= block.timestamp;

        (bool chainlinkOk, uint256 chainlinkPrice, uint256 chainlinkAt) = _readChainlink(chainlink);
        if (!clearFresh && !chainlinkOk) revert NoPrice(asset);

        uint256 cap = redemption < PAR ? redemption : PAR;
        if (clearFresh) {
            mark = clearPrice < cap ? clearPrice : cap;
            at = clearAt;
            // Measured from the capped mark, the value actually reported.
            if (!chainlinkOk || chainlinkPrice * BPS >= mark * (BPS - CHAINLINK_GUARD_BPS)) return (mark, at);
        }
        mark = chainlinkPrice < cap ? chainlinkPrice : cap;
        at = chainlinkAt;
    }

    function _readChainlink(IChainlinkFeed chainlink) internal view returns (bool ok, uint256 price, uint256 at) {
        try chainlink.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer > 0) return (true, uint256(answer), updatedAt);
        } catch {}
    }
}
