// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ClearForkBase, IERC20Loose} from "./ClearForkBase.sol";
import {ClearMetaReserveAdapter} from "../src/ClearMetaReserveAdapter.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";

interface IFlashLender {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
}

interface IClearLock {
    function enterGlobalLock() external;
    function exitGlobalLock() external;
}

/// @notice Borrows from a Clear reserve and, inside the callback, tries to read the adapter's realAssets and
///         to deposit BaseLP into the vault while the reserve's balances are lent out.
contract FlashProbe {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    ClearMetaReserveAdapter internal adapter;
    VaultV2 internal vault;
    bool public realAssetsReverted;
    bool public depositReverted;
    uint256 internal depositLp;

    constructor(ClearMetaReserveAdapter adapter_, VaultV2 vault_) {
        adapter = adapter_;
        vault = vault_;
    }

    function run(address lender, address token, uint256 amount, uint256 depositLp_) external {
        depositLp = depositLp_;
        if (depositLp_ > 0) IERC20Loose(vault.asset()).approve(address(vault), depositLp_);
        IFlashLender(lender).flashLoan(address(this), token, amount, "");
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        try adapter.realAssets() {} catch {
            realAssetsReverted = true;
        }
        if (depositLp > 0) {
            try vault.deposit(depositLp, address(this)) {} catch {
                depositReverted = true;
            }
        }
        IERC20Loose(token).approve(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

/// @notice Takes Clear's ungated global lock, accrues the vault, releases the lock, then redeems in the same
///         transaction: the re-audit's bypass of the first lock guard, which returned the recorded
///         allocation while the lock was held.
contract LockTaker {
    function attack(address factory, VaultV2 vault, uint256 shares) external returns (uint256) {
        IClearLock(factory).enterGlobalLock();
        vault.accrueInterest();
        IClearLock(factory).exitGlobalLock();
        return vault.redeem(shares, address(this), address(this));
    }
}

/// @notice Regression tests for audit findings 1 and 2 (Clear flash loans move `accountedBalance` for the
///         length of the borrower's callback: -24 % / +24 % on realAssets before any guard) and for re-audit
///         finding 1 (the first guard returned a stale recorded allocation under a lock anyone can take).
contract FlashLoanPoCForkTest is ClearForkBase {
    uint256 internal constant ALLOCATION = 500_000e18;

    /// forge-config: default.isolate = true
    function test_metaFlashLoan_cannotPriceOrDepositInsideCallback() public {
        _allocate(ALLOCATION);

        FlashProbe probe = new FlashProbe(adapter, vault);
        uint256 amount = IFlashLender(metaAddr).maxFlashLoan(native);
        deal(native, address(probe), amount); // covers the 1 % fee
        uint256 lp = _mintBaseLp(address(probe), 100_000e18);

        probe.run(metaAddr, native, amount, lp);

        assertTrue(probe.realAssetsReverted(), "realAssets priced the lent-out reserve");
        assertTrue(probe.depositReverted(), "vault deposit went through inside the callback");
    }

    /// forge-config: default.isolate = true
    function test_baseFlashLoan_cannotPriceInsideCallback() public {
        _allocate(ALLOCATION);

        FlashProbe probe = new FlashProbe(adapter, vault);
        uint256 amount = IFlashLender(BASE_RESERVE).maxFlashLoan(USDC);
        deal(USDC, address(probe), amount);
        probe.run(BASE_RESERVE, USDC, amount, 0);

        assertTrue(probe.realAssetsReverted(), "realAssets priced the lent-out reserve");
    }

    /// forge-config: default.isolate = true
    /// @dev Re-audit finding 1: after a native depeg (an unrealized loss), taking the lock no longer lets a
    ///      holder freeze the pre-loss price for the transaction and redeem at it.
    function test_lockTaker_cannotFreezeStalePrice() public {
        _allocate(ALLOCATION);
        LockTaker taker = new LockTaker();
        uint256 shares = _depositBaseLpToVault(address(this), _mintBaseLp(address(this), 100_000e18));
        vault.transfer(address(taker), shares);
        uint256 priceBeforeDepeg = vault.convertToAssets(1e18);

        _pushPrices(PAR_8, USDT_GATE_OPEN_8, NATIVE_DEPEG_8);

        address factory = meta.factory(); // outside expectRevert, which would otherwise catch this call
        vm.expectRevert(ClearMetaReserveAdapter.ClearCallInProgress.selector);
        taker.attack(factory, vault, shares);

        // Outside the lock the loss is realized before anyone is priced, so a redeem gets the post-loss price.
        vault.accrueInterest();
        assertLt(vault.convertToAssets(1e18), priceBeforeDepeg, "depeg loss not realized");
    }
}
