// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Execution venue adapter (DEX router wrapper). The vault pulls nothing from the venue's return value:
///         it measures its own balance deltas, so a lying venue cannot fake fills.
interface IVenue {
    /// @dev Must pull `amountIn` of `tokenIn` from msg.sender (the vault) and send >= `minAmountOut` of `tokenOut` to `recipient`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut);
}
