// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {PushOracle} from "../src/oracles/PushOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {SimVenue} from "../src/mocks/SimVenue.sol";

/// @notice Full TESTNET / local demo stack: mock tokens, push oracle, simulated venue, registry, factory and one funded vault.
///   PRIVATE_KEY=0x... AGENT_ADDRESS=0x... forge script script/DeployDemo.s.sol --rpc-url hashkey_testnet --broadcast
contract DeployDemo is Script {
    struct D {
        MockERC20 usdt;
        MockERC20 wbtc;
        MockERC20 weth;
        PushOracle oracle;
        SimVenue venue;
        StrategyRegistry registry;
        VaultFactory factory;
        AgentVault vault;
        uint256 strategyId;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address agent = vm.envAddress("AGENT_ADDRESS");
        address deployer = vm.addr(pk);
        uint256 btc = vm.envOr("BTC_PRICE_USD", uint256(80_000));
        uint256 eth = vm.envOr("ETH_PRICE_USD", uint256(2_400));
        bytes32 paramsHash = vm.envOr("STRATEGY_PARAMS_HASH", keccak256("sentinel-hedge-ensemble-v1"));

        D memory d;
        vm.startBroadcast(pk);
        d.usdt = new MockERC20("Sentinel Mock USDT", "mUSDT", 6);
        d.wbtc = new MockERC20("Sentinel Mock WBTC", "mWBTC", 8);
        d.weth = new MockERC20("Sentinel Mock WETH", "mWETH", 18);
        d.oracle = new PushOracle(deployer, 2500);
        d.oracle.setPublisher(agent, true);
        {
            address[] memory t = new address[](3);
            uint256[] memory p = new uint256[](3);
            t[0] = address(d.usdt);
            t[1] = address(d.wbtc);
            t[2] = address(d.weth);
            p[0] = 1e18;
            p[1] = btc * 1e18;
            p[2] = eth * 1e18;
            d.oracle.setPrices(t, p);
        }
        d.venue = new SimVenue(d.oracle, 10, 2_000_000); // 10 bps fee, $2M virtual depth
        d.usdt.mint(address(d.venue), 50_000_000e6);
        d.wbtc.mint(address(d.venue), 2_000e8);
        d.weth.mint(address(d.venue), 50_000e18);

        d.registry = new StrategyRegistry();
        d.factory = new VaultFactory();
        d.strategyId = d.registry.register(
            "Sentinel Hedge-Ensemble v1", "https://github.com/mesh-pch/sentinel-hashkey", paramsHash
        );

        address[] memory toks = new address[](2);
        toks[0] = address(d.wbtc);
        toks[1] = address(d.weth);
        address[] memory venues = new address[](1);
        venues[0] = address(d.venue);
        d.vault = d.factory.createVault(
            AgentVault.Config({
                owner: deployer,
                agent: agent,
                baseAsset: address(d.usdt),
                oracle: address(d.oracle),
                registry: address(d.registry),
                strategyId: d.strategyId,
                tokens: toks,
                venues: venues,
                limits: AgentVault.Limits({
                    maxTradeBps: 2500,
                    maxDailyVolumeBps: 15000,
                    maxDrawdownBps: 1000,
                    maxSlippageBps: 100,
                    minIntervalSec: 20,
                    maxOracleAge: 3600
                })
            })
        );
        d.usdt.mint(deployer, 100_000e6);
        d.usdt.approve(address(d.vault), type(uint256).max);
        d.vault.deposit(100_000e6);
        vm.stopBroadcast();

        string memory k = "demo";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "agent", agent);
        vm.serializeAddress(k, "mUSDT", address(d.usdt));
        vm.serializeAddress(k, "mWBTC", address(d.wbtc));
        vm.serializeAddress(k, "mWETH", address(d.weth));
        vm.serializeAddress(k, "PushOracle", address(d.oracle));
        vm.serializeAddress(k, "SimVenue", address(d.venue));
        vm.serializeAddress(k, "StrategyRegistry", address(d.registry));
        vm.serializeAddress(k, "VaultFactory", address(d.factory));
        vm.serializeUint(k, "deployBlock", block.number);
        vm.serializeUint(k, "strategyId", d.strategyId);
        string memory out = vm.serializeAddress(k, "AgentVault", address(d.vault));
        vm.writeJson(out, string.concat("./deployments/", vm.toString(block.chainid), ".json"));

        console2.log("AgentVault", address(d.vault));
    }
}
