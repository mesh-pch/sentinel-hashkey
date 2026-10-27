// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IVenue} from "../interfaces/IVenue.sol";

/// @title SimVenue
/// @notice TESTNET-ONLY simulated exchange: fills at the oracle price minus a fee and a size-dependent price impact
///         (impact bps = tradeValue / (2 * depth)). HashKey Chain testnet has no public liquidity for our mock
///         tokens, so this gives the agent a realistic-enough venue. Production deployments plug a real DEX
///         router behind the same `IVenue` interface.
contract SimVenue is IVenue {
    using SafeERC20 for IERC20;

    error Slippage(uint256 out, uint256 min);
    error NoPrice();
    error NoInventory();

    IPriceOracle public immutable oracle;
    uint256 public immutable feeBps;
    uint256 public immutable depthUsdE18; // virtual liquidity depth in USD (1e18)

    event Swapped(address indexed trader, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(IPriceOracle o, uint256 feeBps_, uint256 depthUsd) {
        oracle = o;
        feeBps = feeBps_;
        depthUsdE18 = depthUsd * 1e18;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        (uint256 pIn,) = oracle.getPrice(tokenIn);
        (uint256 pOut,) = oracle.getPrice(tokenOut);
        if (pIn == 0 || pOut == 0) revert NoPrice();
        uint256 dIn = IERC20Metadata(tokenIn).decimals();
        uint256 dOut = IERC20Metadata(tokenOut).decimals();
        uint256 valueUsdE18 = (amountIn * pIn) / (10 ** dIn);
        uint256 impactBps = (valueUsdE18 * 10_000) / (2 * depthUsdE18);
        uint256 totalBps = feeBps + impactBps;
        if (totalBps >= 10_000) totalBps = 9_999;
        uint256 fair = (amountIn * pIn * (10 ** dOut)) / (pOut * (10 ** dIn));
        return (fair * (10_000 - totalBps)) / 10_000;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        amountOut = quote(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        if (IERC20(tokenOut).balanceOf(address(this)) < amountOut) revert NoInventory();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
