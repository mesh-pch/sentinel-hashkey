// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title AggregatorV3Oracle
/// @notice Production-style adapter: maps tokens to Chainlink-compatible USD feeds and normalises to 1e18.
contract AggregatorV3Oracle is IPriceOracle, Ownable {
    mapping(address => IAggregatorV3) public feedOf;

    event FeedSet(address indexed token, address indexed feed);

    constructor(address owner_) Ownable(owner_) {}

    function setFeed(address token, address feed) external onlyOwner {
        feedOf[token] = IAggregatorV3(feed);
        emit FeedSet(token, feed);
    }

    function getPrice(address token) external view returns (uint256 priceE18, uint256 updatedAt) {
        IAggregatorV3 f = feedOf[token];
        if (address(f) == address(0)) return (0, 0);
        (, int256 a,, uint256 u,) = f.latestRoundData();
        if (a <= 0) return (0, 0);
        uint8 d = f.decimals();
        priceE18 = d <= 18 ? uint256(a) * 10 ** (18 - d) : uint256(a) / 10 ** (d - 18);
        updatedAt = u;
    }
}
