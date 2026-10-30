// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subset of Clear V1 {ClearBaseReserve}. BaseLP is the reserve itself (ERC20, 18 decimals).
/// @dev    Defined locally: Clear's sources are not published as a Solidity package. Signatures match
///         TreveeXYZ/clear-smart-contracts @ b80f8be (v1.0-pashov-audit-fixes, identical to main).
interface IClearBaseReserve {
    function getAssets() external view returns (address[] memory);
    function netBalanceOf(address asset) external view returns (uint256);
    function totalReserveValue() external view returns (uint256);
    function convertToShares(uint256 value) external view returns (uint256);
    function convertToValue(uint256 shares) external view returns (uint256);
    function convertToRedemptionValue(uint256 shares) external view returns (uint256);
    function averagePriceAndRedemptionPrice() external view returns (uint256 price, uint256 redemptionPrice);
    function assetsOnPeg(uint256 toleranceBps) external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function singleAssetFeeBps() external view returns (uint256);

    function deposit(uint256 amount, address receiver, uint256 minLpOut) external returns (uint256 lpMinted);
    function depositSingleAsset(address asset, uint256 amount, address receiver, uint256 minLpOut)
        external
        returns (uint256 lpMinted);
    function withdraw(uint256 lpAmount, address receiver, uint256[] calldata minOut)
        external
        returns (uint256[] memory amountsOut);
    function withdrawSingleAsset(address asset, uint256 lpAmount, address receiver, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    function previewDepositAmounts(uint256 amount) external view returns (uint256[] memory amounts, uint256 lpMinted);
    function previewWithdraw(uint256 lpAmount) external view returns (uint256[] memory amountsOut);
    function previewWithdrawSingleAsset(address asset, uint256 lpAmount)
        external
        view
        returns (uint256 amountOut, uint256 fee);

    function pause() external;
}

/// @notice Subset of Clear V1 {ClearMetaReserve}: one native stablecoin paired with BaseLP. MetaLP is the
///         reserve itself (ERC20, 18 decimals). NAV is on the redemption basis and reads the oracle.
interface IClearMetaReserve {
    function factory() external view returns (address);
    function baseReserve() external view returns (address);
    function nativeToken() external view returns (address);
    function nativeScale() external view returns (uint256);
    function netBalanceOf(address leg) external view returns (uint256);
    function totalReserveValue() external view returns (uint256);
    function convertToValue(uint256 shares) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function singleAssetFeeBps() external view returns (uint256);
    function redemptionProximityBps() external view returns (uint256);

    function deposit(uint256 baseLpAmount, uint256 maxNativeAmount, address receiver, uint256 minLpOut)
        external
        returns (uint256 lpMinted);
    function previewDepositNative(uint256 baseLpAmount) external view returns (uint256 nativeAmount);
    function depositSingleAsset(address asset, uint256 amount, address receiver, uint256 minLpOut)
        external
        returns (uint256 lpMinted);
    function withdraw(uint256 metaLpAmount, address receiver, uint256 minBaseLpOut, uint256 minNativeOut)
        external
        returns (uint256 baseLpOut, uint256 nativeOut);
    function withdrawSingleAsset(address asset, uint256 lpAmount, address receiver, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 minTraderIou,
        address recipient
    ) external returns (uint256 amountOut, uint256 traderIou);

    function pause() external;
}

/// @notice Subset of Clear V1 {ClearReserveFactory}: the protocol-wide re-entrancy lock shared by every
///         reserve it deployed. Non-zero for the whole of any Clear state-changing call, including the
///         borrower callback of a flash loan.
interface IClearFactoryLock {
    function globalLockHolder() external view returns (address holder);
}

/// @notice Subset of Clear V1 {ClearOracle}. Prices and redemption prices use 8 decimals.
interface IClearOracle {
    function getPriceAndRedemptionPrice(address asset) external view returns (uint256 price, uint256 redemptionPrice);
    function oracleConfiguration(address asset)
        external
        view
        returns (
            bool enabled,
            uint8 assetDecimals,
            uint8 oracleDecimals,
            uint256 redemptionPrice,
            uint256 priceTTL,
            uint256 lastUpdateTimestamp,
            uint256 price
        );
    function updateCustomOraclePrices(address[] memory assets, uint256[] memory prices, uint256[] memory publishTimes)
        external;
    function invalidatePrice(address asset) external;
}

/// @notice Subset of OpenZeppelin {AccessManager} used by the tests.
interface IAccessManagerLike {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
}
