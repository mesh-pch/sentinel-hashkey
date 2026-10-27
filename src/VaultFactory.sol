// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentVault} from "./AgentVault.sol";

/// @title VaultFactory
/// @notice Deploys AgentVaults and keeps a public index so explorers / dashboards can discover every agent vault.
contract VaultFactory {
    event VaultCreated(address indexed owner, address indexed vault, address indexed agent, uint256 strategyId);

    address[] public allVaults;
    mapping(address => address[]) private _byOwner;

    /// @dev `c.owner` is forced to msg.sender: you can only create vaults that you own.
    function createVault(AgentVault.Config memory c) external returns (AgentVault vault) {
        c.owner = msg.sender;
        vault = new AgentVault(c);
        allVaults.push(address(vault));
        _byOwner[msg.sender].push(address(vault));
        emit VaultCreated(msg.sender, address(vault), c.agent, c.strategyId);
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _byOwner[owner];
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
