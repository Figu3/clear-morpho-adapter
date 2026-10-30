// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdapter} from "vault-v2/interfaces/IAdapter.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {SafeERC20Lib} from "vault-v2/libraries/SafeERC20Lib.sol";

import {IClearBaseReserve, IClearMetaReserve, IClearOracle, IClearFactoryLock} from "./interfaces/IClear.sol";

/// @title ClearMetaReserveAdapter
/// @notice Morpho Vault V2 adapter for a vault whose asset is Clear V1 BaseLP. It supplies BaseLP to one
///         Clear MetaReserve (BaseLP + one native stablecoin) through the MetaReserve's single-asset path,
///         and takes BaseLP back the same way. See SPEC.md.
/// @dev    The single-asset path is gated: the native token AND every BaseReserve asset must sit within
///         `redemptionProximityBps` of their redemption prices. While the gate is closed allocate and
///         deallocate revert (so does forceDeallocate); vault exits are then served from idle BaseLP and
///         other adapters. That is a property of the MetaReserve, documented in SPEC §5.
///
///         `data` encodings:
///         - allocate:   abi.encode(uint256 minMetaLpOut)
///         - deallocate: abi.encode(uint256 maxMetaLpIn)
///
///         Idle BaseLP (the margin a deallocation over-withdraws) is part of {realAssets} and is spent first
///         by the next deallocation.
contract ClearMetaReserveAdapter is IAdapter {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @dev Morpho VaultV2's ceiling on a force-deallocate penalty (MAX_FORCE_DEALLOCATE_PENALTY).
    uint256 internal constant MORPHO_MAX_FORCE_DEALLOCATE_PENALTY = 0.02e18;
    /// @dev ClearOracle prices carry 8 decimals; marks are 1e18.
    uint256 internal constant ORACLE_ONE = 1e8;
    uint256 internal constant ORACLE_TO_WAD = 1e10;
    /// @dev MetaReserve virtual share offset (VIRTUAL_SHARES in ClearMetaReserve).
    uint256 internal constant META_VIRTUAL_SHARES = 1;
    /// @dev Extra MetaLP burned on deallocation to cover the spread fee and rounding, in bps.
    uint256 public constant DEALLOCATE_MARGIN_BPS = 5;

    address public immutable parentVault;
    IClearMetaReserve public immutable metaReserve;
    IClearBaseReserve public immutable baseReserve;
    address public immutable nativeToken;
    uint256 public immutable nativeScale;
    IClearOracle public immutable oracle;
    /// @notice The Clear factory whose lock both reserves share (a MetaReserve refuses a BaseReserve from
    ///         another factory at initialization).
    IClearFactoryLock public immutable clearFactory;
    bytes32 public immutable adapterId;
    bytes32 public immutable reserveId;
    bytes32 public immutable protocolId;
    /// @notice Haircut applied in {realAssets} for the cost of exiting into BaseLP.
    uint256 public immutable exitFeeBps;
    /// @notice Haircut on the last known native price as soon as the oracle stops answering.
    uint256 public immutable staleHaircutBps;
    /// @notice Further haircut per day since that price was published, so a long outage (when a depeg is
    ///         most likely to be hidden) writes the native leg down to zero instead of carrying it at an old
    ///         mark. Losses are realized at once by the vault; recovery comes back at its maxRate.
    uint256 public immutable staleDecayBpsPerDay;
    /// @notice Smallest vault force-deallocate penalty (WAD) under which {deallocate} refuses forceDeallocate,
    ///         so nobody can make the vault pay the single-asset exit fee for free.
    uint256 public immutable minForceDeallocatePenalty;

    /// @notice Last live min(market, redemption, $1) of the native token, 1e18, and the oracle PUBLISH time of
    ///         the price behind it (not the time it was read, so a late poke cannot reset its age). Used as the
    ///         stale fallback only when the oracle holds no price at all (an invalidated feed). Zero until
    ///         first read, which values the native leg at nothing if the oracle has never answered.
    uint256 public lastNativeMark;
    uint256 public lastMarkAt;

    struct Params {
        address parentVault;
        address metaReserve;
        address oracle;
        uint256 exitFeeBps;
        uint256 staleHaircutBps;
        uint256 staleDecayBpsPerDay;
        uint256 minForceDeallocatePenalty;
    }

    event MarkUpdated(uint256 nativeMark);

    error NotAuthorized();
    error InvalidParameters();
    error MaxMetaLpInExceeded(uint256 metaLpIn, uint256 maxMetaLpIn);
    error InsufficientExit(uint256 available, uint256 needed);
    error ForceDeallocatePenaltyTooLow(uint256 penalty, uint256 minPenalty);
    error ClearCallInProgress();

    constructor(Params memory p) {
        if (p.parentVault == address(0) || p.metaReserve == address(0) || p.oracle == address(0)) {
            revert InvalidParameters();
        }
        if (p.exitFeeBps >= BPS || p.staleHaircutBps >= BPS || p.staleDecayBpsPerDay > BPS) {
            revert InvalidParameters();
        }
        // A floor above Morpho's maximum penalty would disable forceDeallocate for good.
        if (p.minForceDeallocatePenalty > MORPHO_MAX_FORCE_DEALLOCATE_PENALTY) revert InvalidParameters();
        address base = IClearMetaReserve(p.metaReserve).baseReserve();
        if (IVaultV2(p.parentVault).asset() != base) revert InvalidParameters();

        parentVault = p.parentVault;
        metaReserve = IClearMetaReserve(p.metaReserve);
        baseReserve = IClearBaseReserve(base);
        nativeToken = IClearMetaReserve(p.metaReserve).nativeToken();
        nativeScale = IClearMetaReserve(p.metaReserve).nativeScale();
        oracle = IClearOracle(p.oracle);
        clearFactory = IClearFactoryLock(IClearMetaReserve(p.metaReserve).factory());
        adapterId = keccak256(abi.encode("this", address(this)));
        reserveId = keccak256(abi.encode("clear-reserve", p.metaReserve));
        protocolId = keccak256(abi.encode("clear-protocol"));
        exitFeeBps = p.exitFeeBps;
        staleHaircutBps = p.staleHaircutBps;
        staleDecayBpsPerDay = p.staleDecayBpsPerDay;
        minForceDeallocatePenalty = p.minForceDeallocatePenalty;

        SafeERC20Lib.safeApprove(base, p.parentVault, type(uint256).max);
        SafeERC20Lib.safeApprove(base, p.metaReserve, type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Ids
    // ---------------------------------------------------------------------

    /// @notice abi.encode preimages of {ids}, in the same order, for the vault's cap setters.
    function idsData() public view returns (bytes[] memory data) {
        data = new bytes[](3);
        data[0] = abi.encode("this", address(this));
        data[1] = abi.encode("clear-reserve", address(metaReserve));
        data[2] = abi.encode("clear-protocol");
    }

    function ids() public view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](3);
        ids_[0] = adapterId;
        ids_[1] = reserveId;
        ids_[2] = protocolId;
    }

    // ---------------------------------------------------------------------
    // IAdapter
    // ---------------------------------------------------------------------

    /// @dev The vault has already transferred `assets` BaseLP to this adapter.
    function allocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256) {
        if (msg.sender != parentVault) revert NotAuthorized();
        uint256 minMetaLpOut = abi.decode(data, (uint256));

        if (assets > 0) metaReserve.depositSingleAsset(address(baseReserve), assets, address(this), minMetaLpOut);
        _refreshMark();

        return (ids(), _change(_realAssets()));
    }

    /// @dev The vault pulls `assets` BaseLP from this adapter right after this call returns.
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address)
        external
        returns (bytes32[] memory, int256)
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        if (selector == IVaultV2.forceDeallocate.selector) {
            uint256 penalty = IVaultV2(parentVault).forceDeallocatePenalty(address(this));
            if (penalty < minForceDeallocatePenalty) {
                revert ForceDeallocatePenaltyTooLow(penalty, minForceDeallocatePenalty);
            }
        }
        uint256 maxMetaLpIn = abi.decode(data, (uint256));

        uint256 idle = baseReserve.balanceOf(address(this));
        if (assets > idle) _withdraw(assets - idle, maxMetaLpIn);
        _refreshMark();

        return (ids(), _change(_realAssets() - assets));
    }

    /// @notice BaseLP value of the position: the adapter's pro-rata claim on both MetaReserve legs (net of
    ///         IOU debt), the native leg converted at min(market, redemption, $1) over BaseLP's PAR value per
    ///         share, less {exitFeeBps}, plus idle BaseLP. Only the native mark reads the oracle, under
    ///         try/catch, so a stale or invalidated oracle never makes it revert.
    /// @dev    Reverts {ClearCallInProgress} while the Clear factory lock is held, i.e. only inside the
    ///         transaction that holds it (see {_realAssets}). Every other transaction prices normally.
    function realAssets() external view returns (uint256) {
        return _realAssets();
    }

    // ---------------------------------------------------------------------
    // Mark
    // ---------------------------------------------------------------------

    /// @notice min(market, redemption, $1) of the native token from the live oracle, 1e18. MAY revert.
    function liveNativeMark() public view returns (uint256) {
        (uint256 price, uint256 redemption) = oracle.getPriceAndRedemptionPrice(nativeToken);
        return _conservativeMark(price, redemption);
    }

    /// @notice The mark {realAssets} uses while the oracle is silent: the last known price less
    ///         staleHaircutBps plus staleDecayBpsPerDay per day since that price was PUBLISHED, floored at
    ///         zero. The last known price is the oracle's last stored one when it still holds it (so a depeg
    ///         pushed after the last poke is not forgotten), otherwise this adapter's {lastNativeMark}.
    function staleNativeMark() public view returns (uint256) {
        (uint256 mark, uint256 at) = _lastKnownMark();
        // ClearOracle rejects future publish times, but liveness must not hang on that.
        uint256 age = block.timestamp > at ? block.timestamp - at : 0;
        uint256 haircut = (staleHaircutBps * WAD + staleDecayBpsPerDay * WAD * age / 1 days) / BPS;
        if (haircut >= WAD) return 0;
        return mark * (WAD - haircut) / WAD;
    }

    /// @notice Permissionless: refresh {lastNativeMark} from the live oracle. Reverts if it is stale.
    function poke() external {
        _storeMark(liveNativeMark());
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Burns enough MetaLP for at least `needed` BaseLP net of the single-asset fee. Any excess stays
    ///      idle here. The NAV reads below need the oracle, as the withdrawal itself does.
    function _withdraw(uint256 needed, uint256 maxMetaLpIn) internal {
        uint256 metaLpBal = metaReserve.balanceOf(address(this));
        uint256 grossAll = _metaLpToBaseLp(metaLpBal);
        uint256 netFactor = BPS - metaReserve.singleAssetFeeBps() - DEALLOCATE_MARGIN_BPS;
        if (grossAll * netFactor / BPS < needed) revert InsufficientExit(grossAll * netFactor / BPS, needed);

        uint256 metaLp = _ceilDiv(metaLpBal * needed * BPS, grossAll * netFactor);
        if (metaLp > metaLpBal) metaLp = metaLpBal;
        if (metaLp > maxMetaLpIn) revert MaxMetaLpInExceeded(metaLp, maxMetaLpIn);
        metaReserve.withdrawSingleAsset(address(baseReserve), metaLp, address(this), needed);
    }

    /// @dev BaseLP a single-asset exit of `metaLp` would pay before fees, mirroring the MetaReserve:
    ///      NAV claim (redemption basis) converted into BaseLP units at the basket's average redemption.
    function _metaLpToBaseLp(uint256 metaLp) internal view returns (uint256) {
        uint256 value = metaReserve.convertToValue(metaLp);
        (, uint256 avgRedemption) = baseReserve.averagePriceAndRedemptionPrice();
        if (avgRedemption == 0) return 0;
        return baseReserve.convertToShares(value * 1e18 / avgRedemption);
    }

    function _realAssets() internal view returns (uint256) {
        // Inside a Clear call (a flash loan's borrower callback in particular) the reserves' accounted
        // balances are lent out, so pricing them moves this value by the borrowed amount either way (audit
        // findings 1 and 2: -24 % / +24 % on a fork). Returning a remembered value instead is NOT safe: the
        // factory lock can be taken by anyone (`enterGlobalLock` is ungated), and the vault accrues once per
        // transaction, so an attacker could freeze an attacker-timed stale price for the rest of the
        // transaction (re-audit finding 1). So refuse to price. The lock is transient: this only blocks vault
        // use inside the transaction that holds it, never across transactions. allocate/deallocate call this
        // after their Clear call has returned and released the lock.
        if (clearFactory.globalLockHolder() != address(0)) revert ClearCallInProgress();

        uint256 idle = baseReserve.balanceOf(address(this));
        uint256 shares = metaReserve.balanceOf(address(this));
        if (shares == 0) return idle;

        // Pro-rata claim on each leg's NET balance, the basis the MetaReserve's balanced exit pays on.
        // The virtual share is in the denominator; the virtual value is ignored, which only lowers it.
        uint256 supply = metaReserve.totalSupply() + META_VIRTUAL_SHARES;
        uint256 baseUnits = metaReserve.netBalanceOf(address(baseReserve)) * shares / supply;
        uint256 nativeUnits = metaReserve.netBalanceOf(nativeToken) * shares / supply;

        // Native leg in BaseLP: its dollar value at the conservative mark over BaseLP's par value per share.
        // Par per share is an upper bound on BaseLP's dollar value, so the conversion never overstates.
        uint256 parPerShare = baseReserve.convertToValue(1e18);
        uint256 nativeInBase =
            parPerShare == 0 ? 0 : nativeUnits * nativeScale * _nativeMark() / 1e18 * 1e18 / parPerShare;

        return (baseUnits + nativeInBase) * (BPS - exitFeeBps) / BPS + idle;
    }

    /// @dev Live mark when the oracle answers, otherwise {staleNativeMark}.
    function _nativeMark() internal view returns (uint256) {
        try this.liveNativeMark() returns (uint256 mark) {
            return mark;
        } catch {
            return staleNativeMark();
        }
    }

    /// @dev The oracle's stored price and its publish time whenever the oracle still holds one: every mark this
    ///      adapter ever stored was read from that same slot, so it is never newer. Otherwise (an invalidated
    ///      feed) {lastNativeMark} and its publish time. The storage read does not check freshness, so it does
    ///      not revert when the price is stale; it is still wrapped, since liveness must not hang on it.
    function _lastKnownMark() internal view returns (uint256 mark, uint256 at) {
        (bool held, uint256 price, uint256 redemption, uint256 publishedAt) = _storedOraclePrice();
        if (held) return (_conservativeMark(price, redemption), publishedAt);
        return (lastNativeMark, lastMarkAt);
    }

    /// @dev The native token's last pushed price as stored by the oracle, whatever its age.
    function _storedOraclePrice()
        internal
        view
        returns (bool held, uint256 price, uint256 redemption, uint256 publishedAt)
    {
        try oracle.oracleConfiguration(nativeToken) returns (
            bool, uint8, uint8, uint256 r, uint256, uint256 at, uint256 p
        ) {
            if (at != 0 && p != 0) return (true, p, r, at);
        } catch {}
    }

    /// @dev min(price, redemption, $1) from 8-decimal oracle values, as a 1e18 mark.
    function _conservativeMark(uint256 price, uint256 redemption) internal pure returns (uint256) {
        uint256 m = price < redemption ? price : redemption;
        if (m > ORACLE_ONE) m = ORACLE_ONE;
        return m * ORACLE_TO_WAD;
    }

    function _refreshMark() internal {
        try this.liveNativeMark() returns (uint256 mark) {
            _storeMark(mark);
        } catch {}
    }

    /// @dev Records `mark` with the publish time of the oracle price it came from, so its age starts when the
    ///      price was observed, not when someone happened to poke (re-audit finding 2).
    function _storeMark(uint256 mark) internal {
        (bool held,,, uint256 publishedAt) = _storedOraclePrice();
        lastNativeMark = mark;
        lastMarkAt = held && publishedAt <= block.timestamp ? publishedAt : block.timestamp;
        emit MarkUpdated(mark);
    }

    /// @dev Change in this adapter's allocation, given its new estimated position.
    function _change(uint256 newAllocation) internal view returns (int256) {
        // forge-lint: disable-next-item(unsafe-typecast) both are BaseLP amounts, far below 2**255.
        return int256(newAllocation) - int256(IVaultV2(parentVault).allocation(adapterId));
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
