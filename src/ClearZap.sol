// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {SafeERC20Lib} from "vault-v2/libraries/SafeERC20Lib.sol";

import {IClearBaseReserve, IClearOracle} from "./interfaces/IClear.sol";

interface IUniswapV3PoolSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @title ClearZap
/// @notice Stateless periphery between USDC/USDT and shares of a Morpho Vault V2 whose asset is Clear V1
///         BaseLP. See SPEC.md.
/// @dev    Entry (USDC or USDT -> BaseLP -> vault shares) and exit (shares -> BaseLP -> USDC or USDT) try the
///         BaseReserve single-asset path first. When it reverts (proximity gate closed, or not enough of the
///         asset unencumbered) they fall back to the balanced path: a balanced `deposit` / pro-rata
///         `withdraw`, with the other leg swapped either
///         - on the Uniswap V3 USDC/USDT pool when `swapData` is empty: fully on-chain, so a contract
///           integrator can always use it; or
///         - through the aggregator router (KyberSwap) when the caller passes a route built off-chain as
///           `swapData`: better execution for size, at the cost of an API call before the transaction.
///
///         Every SWAP is bounded twice: by the caller's `minShares` / `minAmountOut`, and internally by the
///         live oracle cross-rate less {maxSwapSlippageBps}, so a caller passing 0 (or a bad route) is still
///         not filled past that bound. The single-asset path has no swap and no internal bound: it pays the
///         reserve's own fee at its own price, and only the caller's minimum protects it. The aggregator only ever gets an exact allowance, reset to zero after
///         the call, and its result is measured by balance deltas, never trusted. The zap holds nothing
///         between calls; dust goes back to the caller.
contract ClearZap {
    uint256 internal constant BPS = 10_000;
    /// @dev Reserve par values are 18-decimal; USDC and USDT are 6.
    uint256 internal constant PAR_TO_TOKEN = 1e12;
    /// @dev TickMath bounds, exclusive.
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    IVaultV2 public immutable vault;
    IClearBaseReserve public immutable baseReserve;
    IClearOracle public immutable oracle;
    /// @notice Uniswap V3 USDC/USDT pool. token0 = USDC, token1 = USDT.
    address public immutable usdtPool;
    /// @notice Aggregator router that executes caller-supplied `swapData` (KyberSwap MetaAggregationRouterV2).
    address public immutable aggregator;
    /// @notice Worst acceptable execution versus the oracle cross-rate on the balanced path.
    uint256 public immutable maxSwapSlippageBps;

    bool private transient _entered;

    event ZapDeposit(
        address indexed caller,
        address indexed receiver,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 baseLp,
        uint256 shares,
        bool viaAggregator,
        bool singleAsset
    );
    event ZapRedeem(
        address indexed caller,
        address indexed receiver,
        address indexed tokenOut,
        uint256 shares,
        uint256 baseLp,
        uint256 amountOut,
        bool viaAggregator,
        bool singleAsset
    );

    error InvalidParameters();
    error UnsupportedToken(address token);
    error NotAuthorized();
    error Reentrancy();
    error SlippageExceeded(uint256 got, uint256 min);
    error AggregatorOverspent(uint256 spent, uint256 maxSpent);
    error AggregatorCallFailed(bytes reason);
    error UnsoldLeg(uint256 unsold, uint256 maxUnsold);

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address vault_, address oracle_, address usdtPool_, address aggregator_, uint256 maxSwapSlippageBps_) {
        if (vault_ == address(0) || oracle_ == address(0) || usdtPool_ == address(0) || aggregator_ == address(0)) {
            revert InvalidParameters();
        }
        // A call to an address without code succeeds and does nothing.
        if (aggregator_.code.length == 0) revert InvalidParameters();
        if (maxSwapSlippageBps_ >= BPS) revert InvalidParameters();
        if (IUniswapV3PoolSwap(usdtPool_).token0() != USDC || IUniswapV3PoolSwap(usdtPool_).token1() != USDT) {
            revert InvalidParameters();
        }
        address base = IVaultV2(vault_).asset();
        address[] memory assets = IClearBaseReserve(base).getAssets();
        if (assets.length != 2 || assets[0] != USDC || assets[1] != USDT) revert InvalidParameters();

        vault = IVaultV2(vault_);
        baseReserve = IClearBaseReserve(base);
        oracle = IClearOracle(oracle_);
        usdtPool = usdtPool_;
        aggregator = aggregator_;
        maxSwapSlippageBps = maxSwapSlippageBps_;

        SafeERC20Lib.safeApprove(USDC, base, type(uint256).max);
        SafeERC20Lib.safeApprove(USDT, base, type(uint256).max);
        SafeERC20Lib.safeApprove(base, vault_, type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Entry / exit
    // ---------------------------------------------------------------------

    /// @notice Pull `amountIn` of USDC or USDT, turn it into BaseLP and deposit it in the vault for `receiver`.
    /// @param swapData Empty to use the Uniswap pool on the balanced path; otherwise an aggregator route that
    ///                 sells at most {previewBalancedDeposit}'s `maxSell` of `tokenIn` for the other token, with
    ///                 this zap as sender and recipient. Ignored when the single-asset path is open.
    function deposit(address tokenIn, uint256 amountIn, address receiver, uint256 minShares, bytes calldata swapData)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireSupported(tokenIn);
        // Measured, not assumed: a fee-on-transfer switch on USDT would otherwise leave the zap short.
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        SafeERC20Lib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        amountIn = IERC20(tokenIn).balanceOf(address(this)) - before;

        uint256 baseLp;
        bool single;
        try baseReserve.depositSingleAsset(tokenIn, amountIn, address(this), 0) returns (uint256 minted) {
            baseLp = minted;
            single = true;
        } catch {
            baseLp = _depositBalanced(tokenIn, amountIn, swapData);
        }

        shares = vault.deposit(baseLp, receiver);
        if (shares < minShares) revert SlippageExceeded(shares, minShares);
        _refundDust(msg.sender);

        emit ZapDeposit(msg.sender, receiver, tokenIn, amountIn, baseLp, shares, !single && swapData.length > 0, single);
    }

    /// @notice Redeem `shares` of the caller (needs an allowance to this zap) and pay `tokenOut` to `receiver`.
    /// @param swapData Empty to use the Uniswap pool on the balanced path; otherwise an aggregator route that
    ///                 sells at most {previewBalancedRedeem}'s `otherToSell` of the other token for `tokenOut`,
    ///                 with this zap as sender and recipient. Ignored when the single-asset path is open.
    function redeem(
        uint256 shares,
        address tokenOut,
        address receiver,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external nonReentrant returns (uint256 amountOut) {
        _requireSupported(tokenOut);
        uint256 baseLp = vault.redeem(shares, address(this), msg.sender);

        bool single;
        try baseReserve.withdrawSingleAsset(tokenOut, baseLp, address(this), 0) {
            single = true;
        } catch {
            _withdrawBalanced(tokenOut, baseLp, swapData);
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this));
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);
        SafeERC20Lib.safeTransfer(tokenOut, receiver, amountOut);
        _refundDust(msg.sender);

        emit ZapRedeem(msg.sender, receiver, tokenOut, shares, baseLp, amountOut, !single && swapData.length > 0, single);
    }

    // ---------------------------------------------------------------------
    // Route building helpers (for an off-chain aggregator quote)
    // ---------------------------------------------------------------------

    /// @notice On the balanced path, the most `tokenIn` the zap lets a route sell (`maxSell`) and the least of the
    ///         other token it must receive (`otherNeeded`). Build an exact-input route selling at most `maxSell`
    ///         that returns at least `otherNeeded`. Valid for the current block; reverts if the oracle is stale.
    function previewBalancedDeposit(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 maxSell, uint256 otherNeeded)
    {
        _requireSupported(tokenIn);
        (, uint256[] memory a, uint256 maxInPerOut) = _sizeBalanced(tokenIn, amountIn);
        (uint256 i, uint256 j) = tokenIn == USDC ? (0, 1) : (1, 0);
        otherNeeded = a[j];
        maxSell = _maxPaid(a[i], a[j], maxInPerOut, amountIn);
    }

    /// @notice On the balanced path, how much of the other token redeeming `shares` leaves to sell for `tokenOut`.
    function previewBalancedRedeem(uint256 shares, address tokenOut) external view returns (uint256 otherToSell) {
        _requireSupported(tokenOut);
        uint256[] memory amounts = baseReserve.previewWithdraw(vault.previewRedeem(shares));
        otherToSell = amounts[tokenOut == USDC ? 1 : 0];
    }

    // ---------------------------------------------------------------------
    // Uniswap V3
    // ---------------------------------------------------------------------

    /// @dev Only the configured pool can call, and it only calls back the account that started the swap,
    ///      so every callback here belongs to a swap this zap initiated.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != usdtPool) revert NotAuthorized();
        // forge-lint: disable-next-item(unsafe-typecast) positive deltas only.
        if (amount0Delta > 0) SafeERC20Lib.safeTransfer(USDC, msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) SafeERC20Lib.safeTransfer(USDT, msg.sender, uint256(amount1Delta));
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Sizes a balanced deposit of `amountIn` of `tokenIn`: the par to deposit and its per-asset amounts,
    ///      such that both legs plus the worst-case cost of buying the other leg fit in `amountIn`.
    function _sizeBalanced(address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256 par, uint256[] memory a, uint256 maxInPerOut)
    {
        (uint256 i, uint256 j) = tokenIn == USDC ? (0, 1) : (1, 0);
        address other = tokenIn == USDC ? USDT : USDC;
        // Worst acceptable cost of one unit of `other`, in `tokenIn`, 1e18.
        maxInPerOut = _cross(other, tokenIn) * (BPS + maxSwapSlippageBps) / BPS;

        // Deposits scale linearly in `amount`: size the par so both legs plus the worst-case cost fit.
        uint256 probe = amountIn * PAR_TO_TOKEN;
        (a,) = baseReserve.previewDepositAmounts(probe);
        uint256 worst = a[i] + a[j] * maxInPerOut / 1e18;
        par = worst > amountIn ? probe * amountIn / worst : probe;
        (a,) = baseReserve.previewDepositAmounts(par);
    }

    /// @dev Buys the other leg with `tokenIn` (pool or aggregator), then deposits both legs. Whatever the bound
    ///      kept back is refunded as dust.
    function _depositBalanced(address tokenIn, uint256 amountIn, bytes calldata swapData)
        internal
        returns (uint256 baseLp)
    {
        (uint256 par, uint256[] memory a, uint256 maxInPerOut) = _sizeBalanced(tokenIn, amountIn);
        (uint256 i, uint256 j) = tokenIn == USDC ? (0, 1) : (1, 0);
        address other = tokenIn == USDC ? USDT : USDC;

        if (a[j] > 0) {
            uint256 maxPaid = _maxPaid(a[i], a[j], maxInPerOut, amountIn);
            if (swapData.length > 0) {
                (uint256 spent, uint256 got) = _aggregatorSwap(tokenIn, other, maxPaid, swapData);
                // Spending at most maxPaid for at least a[j] is the oracle bound on the realized rate.
                if (spent > maxPaid) revert AggregatorOverspent(spent, maxPaid);
                if (got < a[j]) revert SlippageExceeded(got, a[j]);
            } else {
                bool zeroForOne = tokenIn == USDC;
                // forge-lint: disable-next-item(unsafe-typecast) a[j] is a 6-decimal stablecoin amount.
                (int256 d0, int256 d1) = IUniswapV3PoolSwap(usdtPool).swap(
                    address(this),
                    zeroForOne,
                    -int256(a[j]),
                    zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                    ""
                );
                // forge-lint: disable-next-item(unsafe-typecast) the input delta is positive.
                uint256 paid = uint256(zeroForOne ? d0 : d1);
                if (paid > maxPaid) revert SlippageExceeded(maxPaid, paid);
            }
        }
        baseLp = baseReserve.deposit(par, address(this), 0);
    }

    /// @dev Pro-rata withdrawal, then sells the other leg for `tokenOut` (pool or aggregator).
    function _withdrawBalanced(address tokenOut, uint256 baseLp, bytes calldata swapData) internal {
        baseReserve.withdraw(baseLp, address(this), new uint256[](2));
        address other = tokenOut == USDC ? USDT : USDC;
        uint256 amount = IERC20(other).balanceOf(address(this));
        if (amount == 0) return;

        // Worst acceptable `tokenOut` received per unit of `other`, 1e18.
        uint256 minOutPerIn = _cross(other, tokenOut) * (BPS - maxSwapSlippageBps) / BPS;
        if (swapData.length > 0) {
            (uint256 spent, uint256 got) = _aggregatorSwap(other, tokenOut, amount, swapData);
            // The route must sell (nearly) the whole leg: otherwise the caller gets a USDC/USDT mix while asking
            // for one token, and a route selling nothing would pass the rate bound below. Up to 1 bp may stay
            // unsold (a route quoted off a slightly older balance); it is refunded as dust.
            if (amount - spent > amount / BPS) revert UnsoldLeg(amount - spent, amount / BPS);
            uint256 minGot = spent * minOutPerIn / 1e18;
            if (got < minGot) revert SlippageExceeded(got, minGot);
        } else {
            bool zeroForOne = other == USDC;
            // forge-lint: disable-next-item(unsafe-typecast) amount is a 6-decimal token balance.
            (int256 d0, int256 d1) = IUniswapV3PoolSwap(usdtPool).swap(
                address(this),
                zeroForOne,
                int256(amount),
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                ""
            );
            // forge-lint: disable-next-item(unsafe-typecast) the output delta is negative.
            uint256 received = uint256(-(zeroForOne ? d1 : d0));
            uint256 minReceived = amount * minOutPerIn / 1e18;
            if (received < minReceived) revert SlippageExceeded(received, minReceived);
        }
    }

    /// @dev Most `tokenIn` the swap may spend: the oracle bound on buying `aOther` of the other leg, and never
    ///      more than what is left once the reserve's `aIn` leg is set aside. Rounding in the sizing can put the
    ///      oracle bound 1-3 wei above that room, and a route selling the full bound would then make the deposit
    ///      revert (re-audit, zap finding 1).
    function _maxPaid(uint256 aIn, uint256 aOther, uint256 maxInPerOut, uint256 amountIn)
        internal
        pure
        returns (uint256 maxPaid)
    {
        maxPaid = aOther * maxInPerOut / 1e18 + 1;
        uint256 room = amountIn > aIn ? amountIn - aIn : 0;
        if (maxPaid > room) maxPaid = room;
    }

    /// @dev Runs the caller's route on the aggregator with an allowance of exactly `maxSpend` of `sell`, reset to
    ///      zero afterwards, and reports what actually left and arrived. The route is untrusted: the zap only
    ///      ever holds the current caller's funds, the allowance caps what it can pull, and the callers above
    ///      bound the result against the oracle.
    function _aggregatorSwap(address sell, address buy, uint256 maxSpend, bytes calldata swapData)
        internal
        returns (uint256 spent, uint256 got)
    {
        uint256 sellBefore = IERC20(sell).balanceOf(address(this));
        uint256 buyBefore = IERC20(buy).balanceOf(address(this));

        SafeERC20Lib.safeApprove(sell, aggregator, maxSpend);
        (bool ok, bytes memory ret) = aggregator.call(swapData);
        if (!ok) revert AggregatorCallFailed(ret);
        SafeERC20Lib.safeApprove(sell, aggregator, 0);

        spent = sellBefore - IERC20(sell).balanceOf(address(this));
        got = IERC20(buy).balanceOf(address(this)) - buyBefore;
    }

    /// @dev Units of `quote` one unit of `token` is worth at live oracle prices, 1e18. Both have 6
    ///      decimals. Reverts when the oracle is stale: a swap is never bounded by a remembered price.
    function _cross(address token, address quote) internal view returns (uint256) {
        (uint256 pToken,) = oracle.getPriceAndRedemptionPrice(token);
        (uint256 pQuote,) = oracle.getPriceAndRedemptionPrice(quote);
        return pToken * 1e18 / pQuote;
    }

    function _refundDust(address to) internal {
        uint256 usdc = IERC20(USDC).balanceOf(address(this));
        if (usdc > 0) SafeERC20Lib.safeTransfer(USDC, to, usdc);
        uint256 usdt = IERC20(USDT).balanceOf(address(this));
        if (usdt > 0) SafeERC20Lib.safeTransfer(USDT, to, usdt);
        uint256 lp = baseReserve.balanceOf(address(this));
        if (lp > 0) SafeERC20Lib.safeTransfer(address(baseReserve), to, lp);
    }

    function _requireSupported(address token) internal pure {
        if (token != USDC && token != USDT) revert UnsupportedToken(token);
    }
}
