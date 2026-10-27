// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title PushOracle
/// @notice Simple push oracle for testnets / demos: whitelisted publishers post prices. To limit what a rogue or
///         buggy publisher can do, a single update may move a price by at most `maxMoveBps` (after the first post).
///         For production use `AggregatorV3Oracle` (Chainlink-style feeds) or any other IPriceOracle.
contract PushOracle is IPriceOracle, Ownable {
    error NotPublisher();
    error MoveTooLarge(address token, uint256 oldPrice, uint256 newPrice);
    error LengthMismatch();

    event PricePosted(address indexed token, uint256 priceE18, uint256 timestamp);
    event PublisherSet(address indexed publisher, bool allowed);

    struct Quote {
        uint192 price;
        uint64 updatedAt;
    }

    uint256 public immutable maxMoveBps;
    mapping(address => bool) public isPublisher;
    mapping(address => Quote) private _q;

    constructor(address owner_, uint256 maxMoveBps_) Ownable(owner_) {
        maxMoveBps = maxMoveBps_;
        isPublisher[owner_] = true;
    }

    function setPublisher(address who, bool allowed) external onlyOwner {
        isPublisher[who] = allowed;
        emit PublisherSet(who, allowed);
    }

    function setPrices(address[] calldata tokens, uint256[] calldata pricesE18) external {
        if (!isPublisher[msg.sender]) revert NotPublisher();
        if (tokens.length != pricesE18.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) {
            Quote memory old = _q[tokens[i]];
            uint256 np = pricesE18[i];
            if (old.price != 0) {
                uint256 diff = np > old.price ? np - old.price : old.price - np;
                if (diff * 10_000 > uint256(old.price) * maxMoveBps) revert MoveTooLarge(tokens[i], old.price, np);
            }
            _q[tokens[i]] = Quote(uint192(np), uint64(block.timestamp));
            emit PricePosted(tokens[i], np, block.timestamp);
        }
    }

    function getPrice(address token) external view returns (uint256, uint256) {
        Quote memory q = _q[token];
        return (q.price, q.updatedAt);
    }
}
