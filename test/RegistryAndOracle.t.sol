// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {AggregatorV3Oracle} from "../src/oracles/AggregatorV3Oracle.sol";

contract MockFeed {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;

    constructor(int256 a, uint8 d) {
        answer = a;
        decimals = d;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, updatedAt, 1);
    }
}

contract RegistryAndOracleTest is Test {
    StrategyRegistry reg = new StrategyRegistry();
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function test_RegisterUpdateDeactivate() public {
        vm.prank(alice);
        uint256 id = reg.register("momentum-hedge", "ipfs://a", keccak256("v1"));
        assertEq(id, 1);
        assertTrue(reg.isActive(id));
        assertEq(reg.versionOf(id), 1);

        vm.prank(bob);
        vm.expectRevert(StrategyRegistry.NotAuthor.selector);
        reg.update(id, "ipfs://evil", bytes32(0));

        vm.prank(alice);
        reg.update(id, "ipfs://b", keccak256("v2"));
        assertEq(reg.versionOf(id), 2);
        assertEq(reg.get(id).paramsHash, keccak256("v2"));

        vm.prank(alice);
        reg.setActive(id, false);
        assertFalse(reg.isActive(id));
    }

    function test_EmptyNameAndUnknown() public {
        vm.expectRevert(StrategyRegistry.EmptyName.selector);
        reg.register("", "", 0);
        vm.expectRevert(StrategyRegistry.UnknownStrategy.selector);
        reg.get(7);
    }

    function test_AggregatorNormalisesDecimals() public {
        AggregatorV3Oracle o = new AggregatorV3Oracle(address(this));
        MockFeed f8 = new MockFeed(80_000e8, 8);
        o.setFeed(address(0xB7C), address(f8));
        (uint256 p, uint256 u) = o.getPrice(address(0xB7C));
        assertEq(p, 80_000e18);
        assertEq(u, block.timestamp);
        (p,) = o.getPrice(address(0x1234));
        assertEq(p, 0);
    }
}
