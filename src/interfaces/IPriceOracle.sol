// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal price oracle used by AgentVault. Prices are USD per 1 whole token, scaled to 1e18.
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256 priceE18, uint256 updatedAt);
}
