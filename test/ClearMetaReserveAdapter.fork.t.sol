// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

import {ClearForkBase, IERC20Loose} from "./ClearForkBase.sol";
import {ClearMetaReserveAdapter} from "../src/ClearMetaReserveAdapter.sol";

/// @notice SPEC §7 for the adapter (vault asset = BaseLP), against the live Clear V1 native MetaReserve.
contract ClearMetaReserveAdapterForkTest is ClearForkBase {
    uint256 internal constant ALLOCATION = 500_000e18; // BaseLP

    // =====================================================================
    // §7.1  realAssets() never reverts (Morpho liveness)
    // =====================================================================

    function test_realAssets_doesNotRevert_whenOracleStale() public {
        _allocate(ALLOCATION);
        uint256 liveValue = adapter.realAssets();

        _makeOracleStale();

        uint256 staleValue = adapter.realAssets();
        assertLe(staleValue, liveValue, "stale mark above the live one");
        assertGt(staleValue, 0, "stale mark wiped the position");
        assertApproxEqAbs(
            staleValue, _expectedRealAssets(_expectedStaleMark()), 1e3, "stale value is not the decayed last price"
        );

        // The whole vault keeps working: accrual, and an exit served from idle BaseLP.
        vault.accrueInterest();
        vm.prank(alice);
        vault.withdraw(10_000e18, alice, alice);
    }

    /// @dev Finding 3: the stale haircut grows with the age of the last price, down to a native leg at 0.
    function test_staleMark_decaysWithAge() public {
        _allocate(ALLOCATION);
        _makeOracleStale();
        uint256 day0 = adapter.realAssets();

        vm.warp(block.timestamp + 7 days);
        uint256 day7 = adapter.realAssets();
        assertLt(day7, day0, "stale value did not decay");
        assertApproxEqAbs(day7, _expectedRealAssets(_expectedStaleMark()), 1e3);

        vm.warp(block.timestamp + 120 days);
        assertEq(_expectedStaleMark(), 0);
        assertApproxEqAbs(adapter.realAssets(), _expectedRealAssets(0), 1e3, "native leg not written off");
    }

    /// @dev Finding 3: the fallback starts from the oracle's last PUSHED price, not from an older mark the
    ///      adapter happened to store. A depeg pushed after the last poke is not forgotten when the feed stops.
    function test_staleMark_usesLastPushedPrice_notOlderPoke() public {
        _allocate(ALLOCATION); // stores a mark at peg
        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_DEPEG_8); // no poke afterwards
        uint256 depegLive = adapter.realAssets();

        _makeOracleStale();

        assertLt(adapter.realAssets(), depegLive, "fallback went back to the pre-depeg mark");
        assertApproxEqAbs(adapter.realAssets(), _expectedRealAssets(_expectedStaleMark()), 1e3);
    }

    /// @dev Finding 3: an invalidated price leaves no stored price, so the adapter's own mark is used, aged
    ///      from when it was stored.
    function test_staleMark_fallsBackToAdapterMark_whenPriceInvalidated() public {
        _allocate(ALLOCATION);
        vm.warp(block.timestamp + 2 days);
        vm.prank(PYTH_ORACLE_ADAPTER);
        clearOracle.invalidatePrice(native);

        assertApproxEqAbs(adapter.realAssets(), _expectedRealAssets(_expectedStaleMark()), 1e3);
    }

    /// @dev Re-audit finding 2: a poke after the price was pushed must not reset the mark's age.
    function test_poke_keepsPublishTime() public {
        _allocate(ALLOCATION);
        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_ON_PEG_8);
        // Read back from the oracle: under via_ir, `block.timestamp` in the test body can be cached across warps.
        (,,,,, uint256 publishedAt,) = clearOracle.oracleConfiguration(native);
        vm.warp(publishedAt + 30 minutes); // still within the 1 h TTL
        adapter.poke();
        assertEq(adapter.lastMarkAt(), publishedAt, "poke reset the mark's age");
    }

    function test_realAssets_doesNotRevert_whenNativePriceInvalidated() public {
        _allocate(ALLOCATION);
        vm.prank(PYTH_ORACLE_ADAPTER);
        clearOracle.invalidatePrice(native);

        assertGt(adapter.realAssets(), 0);
        vault.accrueInterest();
    }

    function test_realAssets_doesNotRevert_whenReservesPaused() public {
        _allocate(ALLOCATION);
        _grantPauser();
        meta.pause();
        base.pause();

        assertGt(adapter.realAssets(), 0);
        vault.accrueInterest();
    }

    function test_realAssets_isZero_beforeAnyAllocation() public view {
        assertEq(adapter.realAssets(), 0);
    }

    // =====================================================================
    // §7.2  Valuation is never optimistic
    // =====================================================================

    function test_realAssets_matchesSpecFormula_atPeg() public {
        _allocate(ALLOCATION);
        assertApproxEqAbs(adapter.realAssets(), _expectedRealAssets(_liveNativeMark()), 1e3);
    }

    function test_realAssets_notAboveSingleAssetExit() public {
        _allocate(ALLOCATION);
        uint256 reported = adapter.realAssets();

        uint256 snap = vm.snapshotState();
        uint256 metaLp = meta.balanceOf(address(adapter));
        vm.prank(address(adapter));
        uint256 out = meta.withdrawSingleAsset(BASE_RESERVE, metaLp, address(adapter), 0);
        vm.revertToState(snap);

        assertLe(reported, out + base.balanceOf(address(adapter)), "valued above what an exit pays");
    }

    function test_realAssets_marksNativeAtMarket_duringDepeg() public {
        _allocate(ALLOCATION);
        uint256 atPeg = adapter.realAssets();

        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_DEPEG_8);

        uint256 depegged = adapter.realAssets();
        assertLt(depegged, atPeg, "native depeg not reflected");
        assertApproxEqAbs(depegged, _expectedRealAssets(_liveNativeMark()), 1e3);
    }

    function test_realAssets_notAbovePar_whenPricesAbovePar() public {
        _allocate(ALLOCATION);
        _pushPrices(1.002e8, 1.002e8, 1.002e8);
        assertLe(adapter.realAssets(), _parBound());
    }

    // =====================================================================
    // §7.3  Round trips cost at most the fees they pay
    // =====================================================================

    function test_roundTrip_costBounded() public {
        uint256 before = vault.totalAssets();
        _allocate(ALLOCATION);
        _deallocate(adapter.realAssets());
        _deallocate(adapter.realAssets());
        vault.accrueInterest();

        uint256 loss = before - vault.totalAssets();
        // Entry and exit each pay the MetaReserve single-asset fee; spread fees are zero on peg.
        uint256 maxLoss = ALLOCATION * (2 * meta.singleAssetFeeBps() + 1) / BPS;
        assertLe(loss, maxLoss, "round trip lost more than its fees");
    }

    // =====================================================================
    // §7.4  A depeg swap does not transfer value between vault depositors
    // =====================================================================

    function test_depegSwap_frontrunnerGainsAtMostMaxRate() public {
        _allocate(ALLOCATION);

        address attacker = makeAddr("attacker");
        uint256 stake = _mintBaseLp(attacker, 300_000e18); // stays idle in the vault
        uint256 shares = _depositBaseLpToVault(attacker, stake);
        uint256 t0 = block.timestamp;

        // native depegs; an arbitrageur sells native to the MetaReserve for BaseLP. LPs book the IOU share.
        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_DEPEG_8);
        address arb = makeAddr("arb");
        uint256 amountIn = _nativeAmount(100_000);
        deal(native, arb, amountIn);
        vm.startPrank(arb);
        IERC20Loose(native).approve(metaAddr, amountIn);
        meta.swap(native, BASE_RESERVE, amountIn, 0, 0, arb);
        vm.stopPrank();

        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_ON_PEG_8);
        vm.prank(attacker);
        uint256 out = vault.redeem(shares, attacker, attacker);

        uint256 maxGain = stake * MAX_RATE * (block.timestamp - t0) / 1e18 + 1;
        assertLe(out, stake + maxGain, "front-runner captured the depeg gain");
    }

    // =====================================================================
    // §7.5  forceDeallocate cannot push costs onto other depositors
    // =====================================================================

    function test_forceDeallocate_doesNotLowerSharePrice() public {
        _allocate(VAULT_SEED_PAR * 9 / 10);
        address bob = makeAddr("bob");
        _depositBaseLpToVault(bob, _mintBaseLp(bob, 50_000e18));
        uint256 priceBefore = vault.convertToAssets(1e18);

        vm.prank(bob);
        vault.forceDeallocate(address(adapter), abi.encode(type(uint256).max), 40_000e18, bob);

        assertGe(vault.convertToAssets(1e18), priceBefore, "forceDeallocate diluted the other depositors");
    }

    /// @dev Finding 4: with the vault's penalty below the adapter's floor, forceDeallocate is refused, so
    ///      nobody can make the vault pay the exit fee for free.
    function test_forceDeallocate_revertsWhenPenaltyBelowFloor() public {
        _allocate(ALLOCATION);
        _curate(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), 0)));

        address griefer = makeAddr("griefer");
        _depositBaseLpToVault(griefer, _mintBaseLp(griefer, 10_000e18));
        vm.prank(griefer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearMetaReserveAdapter.ForceDeallocatePenaltyTooLow.selector, 0, MIN_FORCE_DEALLOCATE_PENALTY
            )
        );
        vault.forceDeallocate(address(adapter), abi.encode(type(uint256).max), 5_000e18, griefer);
    }

    /// @dev Finding 4: the floor only applies to forceDeallocate; the allocator still deallocates freely.
    function test_allocatorDeallocate_unaffectedByPenaltyFloor() public {
        _allocate(ALLOCATION);
        _curate(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), 0)));
        _deallocate(100_000e18);
    }

    function test_constructor_rejectsUnreachablePenaltyFloor() public {
        vm.expectRevert(ClearMetaReserveAdapter.InvalidParameters.selector);
        new ClearMetaReserveAdapter(
            ClearMetaReserveAdapter.Params({
                parentVault: address(vault),
                metaReserve: metaAddr,
                oracle: CLEAR_ORACLE,
                exitFeeBps: EXIT_FEE_BPS,
                staleHaircutBps: STALE_HAIRCUT_BPS,
                staleDecayBpsPerDay: STALE_DECAY_BPS_PER_DAY,
                minForceDeallocatePenalty: 0.03e18 // above Morpho's 2 % maximum
            })
        );
    }

    // =====================================================================
    // §7.6  Gate closed: the adapter is immobilised, the vault is not
    // =====================================================================

    function test_deallocate_revertsWhenGateClosed() public {
        _allocate(ALLOCATION);
        _pushPrices(PAR_8, USDT_AT_PAR_8, NATIVE_ON_PEG_8);

        vm.prank(allocator);
        vm.expectRevert();
        vault.deallocate(address(adapter), abi.encode(type(uint256).max), 100_000e18);
    }

    function test_vaultExit_servedFromIdle_whenGateClosed() public {
        _allocate(ALLOCATION);
        _pushPrices(PAR_8, USDT_AT_PAR_8, NATIVE_ON_PEG_8);

        uint256 before = base.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(200_000e18, alice, alice);
        assertEq(base.balanceOf(alice), before + 200_000e18);
    }

    // =====================================================================
    // §7.7  Reported changes track the position
    // =====================================================================

    function test_allocation_tracksRealAssets_acrossCalls() public {
        bytes32 id = adapter.adapterId();

        _allocate(ALLOCATION);
        assertApproxEqAbs(vault.allocation(id), adapter.realAssets(), 1, "after allocate");

        _deallocate(100_000e18);
        assertApproxEqAbs(vault.allocation(id), adapter.realAssets(), 1, "after deallocate");

        _allocate(50_000e18);
        assertApproxEqAbs(vault.allocation(id), adapter.realAssets(), 1, "after second allocate");
    }

    function test_ids_shareReserveAndProtocolIds() public {
        _allocate(ALLOCATION);
        assertEq(vault.allocation(adapter.reserveId()), vault.allocation(adapter.adapterId()));
        assertEq(vault.allocation(adapter.protocolId()), vault.allocation(adapter.adapterId()));
    }

    // =====================================================================
    // §7.8  Access control and inputs
    // =====================================================================

    function test_allocate_onlyParentVault() public {
        vm.expectRevert(ClearMetaReserveAdapter.NotAuthorized.selector);
        adapter.allocate(abi.encode(uint256(0)), 1e18, bytes4(0), address(this));
    }

    function test_deallocate_onlyParentVault() public {
        vm.expectRevert(ClearMetaReserveAdapter.NotAuthorized.selector);
        adapter.deallocate(abi.encode(type(uint256).max), 1e18, bytes4(0), address(this));
    }

    function test_allocate_rejectsEmptyData() public {
        vm.prank(address(vault));
        vm.expectRevert();
        adapter.allocate("", 1e18, bytes4(0), address(this));
    }

    function test_deallocate_respectsMaxLpIn() public {
        _allocate(ALLOCATION);
        vm.prank(allocator);
        vm.expectRevert();
        vault.deallocate(address(adapter), abi.encode(uint256(1)), 100_000e18);
    }

    function test_poke_refreshesMark() public {
        _allocate(ALLOCATION);
        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_DEPEG_8);
        adapter.poke();
        assertEq(adapter.lastNativeMark(), _liveNativeMark());
        assertEq(adapter.lastMarkAt(), block.timestamp);
    }

    function test_constructor_rejectsVaultWithOtherAsset() public {
        address usdcVault = address(new VaultV2Like(USDC));
        vm.expectRevert(ClearMetaReserveAdapter.InvalidParameters.selector);
        _newAdapter(usdcVault);
    }
}

/// @dev Minimal stand-in exposing only `asset()`, for the constructor check.
contract VaultV2Like {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @notice The whole adapter suite again, on the PYUSD MetaReserve: a 6-decimal native token
///         (nativeScale = 1e12) where USDS has 18. Covers the decimal paths of the valuation, the stale
///         mark and the depeg swap.
contract ClearMetaReserveAdapterPyusdForkTest is ClearMetaReserveAdapterForkTest {
    address internal constant META_PYUSD = 0x4ff500233d1898AE2aC5Ad61296780ba35dcAeD4;

    function _selectMetaReserve() internal pure override returns (address) {
        return META_PYUSD;
    }

    function test_pyusd_isSixDecimals() public view {
        assertEq(meta.nativeScale(), 1e12);
        assertEq(adapter.nativeScale(), 1e12);
    }
}
