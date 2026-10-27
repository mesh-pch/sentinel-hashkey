// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StrategyRegistry
/// @notice Public, append-only-ish registry of AI trading strategies. A strategy is identified by an id and
///         commits to a content hash of its parameters / code bundle (`paramsHash`) plus a metadata URI.
///         Vaults check `isActive(id)` on every trade, so an author can kill a strategy network-wide.
contract StrategyRegistry {
    struct Strategy {
        address author;
        uint64 createdAt;
        uint32 version;
        bool active;
        bytes32 paramsHash;
        string name;
        string uri;
    }

    error NotAuthor();
    error UnknownStrategy();
    error EmptyName();

    event StrategyRegistered(uint256 indexed id, address indexed author, string name, string uri, bytes32 paramsHash);
    event StrategyUpdated(uint256 indexed id, uint32 version, string uri, bytes32 paramsHash);
    event StrategyStatus(uint256 indexed id, bool active);

    uint256 public count;
    mapping(uint256 => Strategy) private _strategies;

    function register(string calldata name, string calldata uri, bytes32 paramsHash) external returns (uint256 id) {
        if (bytes(name).length == 0) revert EmptyName();
        id = ++count;
        _strategies[id] = Strategy({
            author: msg.sender,
            createdAt: uint64(block.timestamp),
            version: 1,
            active: true,
            paramsHash: paramsHash,
            name: name,
            uri: uri
        });
        emit StrategyRegistered(id, msg.sender, name, uri, paramsHash);
    }

    /// @notice Publish a new version (new code/params commitment) of an existing strategy.
    function update(uint256 id, string calldata uri, bytes32 paramsHash) external {
        Strategy storage s = _author(id);
        s.version += 1;
        s.uri = uri;
        s.paramsHash = paramsHash;
        emit StrategyUpdated(id, s.version, uri, paramsHash);
    }

    function setActive(uint256 id, bool active) external {
        _author(id).active = active;
        emit StrategyStatus(id, active);
    }

    function isActive(uint256 id) external view returns (bool) {
        return _strategies[id].active;
    }

    function versionOf(uint256 id) external view returns (uint32) {
        return _strategies[id].version;
    }

    function get(uint256 id) external view returns (Strategy memory) {
        if (_strategies[id].author == address(0)) revert UnknownStrategy();
        return _strategies[id];
    }

    function _author(uint256 id) private view returns (Strategy storage s) {
        s = _strategies[id];
        if (s.author == address(0)) revert UnknownStrategy();
        if (s.author != msg.sender) revert NotAuthor();
    }
}
