// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// @notice Production-style deployment (use on HashKey Chain MAINNET, chain id 177):
///         StrategyRegistry + VaultFactory, and registers the Sentinel reference strategy.
///   PRIVATE_KEY=0x... forge script script/DeployCore.s.sol --rpc-url hashkey_mainnet --broadcast
contract DeployCore is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        bytes32 paramsHash = vm.envOr("STRATEGY_PARAMS_HASH", keccak256("sentinel-hedge-ensemble-v1"));
        string memory uri = vm.envOr("STRATEGY_URI", string("https://github.com/mesh-pch/sentinel-hashkey"));

        vm.startBroadcast(pk);
        StrategyRegistry registry = new StrategyRegistry();
        VaultFactory factory = new VaultFactory();
        uint256 id = registry.register("Sentinel Hedge-Ensemble v1", uri, paramsHash);
        vm.stopBroadcast();

        string memory k = "core";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "StrategyRegistry", address(registry));
        vm.serializeAddress(k, "VaultFactory", address(factory));
        string memory out = vm.serializeUint(k, "strategyId", id);
        vm.writeJson(out, string.concat("./deployments/", vm.toString(block.chainid), "-core.json"));

        console2.log("StrategyRegistry", address(registry));
        console2.log("VaultFactory    ", address(factory));
        console2.log("strategyId      ", id);
    }
}
