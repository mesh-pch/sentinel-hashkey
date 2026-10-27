// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {PushOracle} from "../src/oracles/PushOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {SimVenue} from "../src/mocks/SimVenue.sol";
import {IVenue} from "../src/interfaces/IVenue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev venue that tries to steal: pulls double and returns nothing
contract EvilVenue is IVenue {
    function swap(address tokenIn, address, uint256 amountIn, uint256, address) external returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn); // pulls what it was approved for, gives nothing back
        return 0;
    }
}

contract AgentVaultTest is Test {
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");

    MockERC20 usdt;
    MockERC20 wbtc;
    MockERC20 weth;
    PushOracle oracle;
    SimVenue venue;
    StrategyRegistry registry;
    VaultFactory factory;
    AgentVault vault;
    uint256 sid;

    uint256 constant BTC = 80_000e18;
    uint256 constant ETH = 2_400e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdt = new MockERC20("Mock USDT", "mUSDT", 6);
        wbtc = new MockERC20("Mock WBTC", "mWBTC", 8);
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        oracle = new PushOracle(address(this), 2500);
        _prices(1e18, BTC, ETH);
        venue = new SimVenue(oracle, 10, 1_000_000);
        usdt.mint(address(venue), 1_000_000e6);
        wbtc.mint(address(venue), 100e8);
        weth.mint(address(venue), 5_000e18);
        registry = new StrategyRegistry();
        factory = new VaultFactory();

        vm.prank(owner);
        sid = registry.register("test-strategy", "ipfs://x", keccak256("params"));

        address[] memory toks = new address[](2);
        toks[0] = address(wbtc);
        toks[1] = address(weth);
        address[] memory venues = new address[](1);
        venues[0] = address(venue);
        AgentVault.Config memory c = AgentVault.Config({
            owner: address(0),
            agent: agent,
            baseAsset: address(usdt),
            oracle: address(oracle),
            registry: address(registry),
            strategyId: sid,
            tokens: toks,
            venues: venues,
            limits: AgentVault.Limits({
                maxTradeBps: 2500,
                maxDailyVolumeBps: 6000,
                maxDrawdownBps: 1000,
                maxSlippageBps: 100,
                minIntervalSec: 60,
                maxOracleAge: 3600
            })
        });
        vm.prank(owner);
        vault = factory.createVault(c);

        usdt.mint(owner, 10_000e6);
        vm.startPrank(owner);
        usdt.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6);
        vm.stopPrank();
    }

    function _prices(uint256 u, uint256 b, uint256 e) internal {
        address[] memory t = new address[](3);
        uint256[] memory p = new uint256[](3);
        t[0] = address(usdt);
        t[1] = address(wbtc);
        t[2] = address(weth);
        p[0] = u;
        p[1] = b;
        p[2] = e;
        oracle.setPrices(t, p);
    }

    function _trade(address tin, address tout, uint256 amtIn, uint256 slippageBps) internal returns (AgentVault.Trade memory t) {
        (uint256 pIn,) = oracle.getPrice(tin);
        (uint256 pOut,) = oracle.getPrice(tout);
        uint256 fair = (amtIn * pIn * (10 ** MockERC20(tout).decimals())) / (pOut * (10 ** MockERC20(tin).decimals()));
        t = AgentVault.Trade({
            venue: address(venue),
            tokenIn: tin,
            tokenOut: tout,
            amountIn: amtIn,
            minAmountOut: (fair * (10_000 - slippageBps)) / 10_000,
            decisionHash: keccak256(abi.encode("d", amtIn, block.timestamp))
        });
    }

    // ------------------------------------------------------------ happy path
    function test_NavAndTrade() public {
        assertEq(vault.nav(), 10_000e6);
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 2_000e6, 90);
        vm.prank(agent);
        uint256 out = vault.executeTrade(t);
        assertGt(out, 0);
        assertEq(wbtc.balanceOf(address(vault)), out);
        // NAV only lost fee + impact (~0.1% + 0.1% on 20% of NAV)
        assertApproxEqAbs(vault.nav(), 10_000e6, 10e6);
        assertEq(vault.logCount(), 1);
        assertTrue(vault.logHead() != bytes32(0));
    }

    function test_HoldIsLoggedInChain() public {
        bytes32 h0 = vault.logHead();
        vm.prank(agent);
        vault.recordHold(keccak256("hold"));
        assertTrue(vault.logHead() != h0);
        assertEq(vault.logCount(), 1);
    }

    // ------------------------------------------------------------ access control
    function test_OnlyAgentCanTrade() public {
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 100e6, 50);
        vm.prank(stranger);
        vm.expectRevert(AgentVault.NotAgent.selector);
        vault.executeTrade(t);
        vm.prank(owner);
        vm.expectRevert(AgentVault.NotAgent.selector);
        vault.executeTrade(t);
    }

    function test_AgentCannotWithdrawOrChangeConfig() public {
        vm.startPrank(agent);
        vm.expectRevert();
        vault.withdraw(address(usdt), 1, agent);
        vm.expectRevert();
        vault.setLimits(AgentVault.Limits(10000, 10000, 10000, 10000, 0, 1));
        vm.expectRevert();
        vault.setVenue(address(1), true);
        vm.expectRevert();
        vault.setAgent(agent);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ limits
    function test_RevertTradeTooLarge() public {
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 2_501e6, 50);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.TradeTooLarge.selector, 2_501e6, 2_500e6));
        vault.executeTrade(t);
    }

    function test_RevertDailyVolume() public {
        // 25% x 3 = 75% > 60% daily cap; third trade must fail
        for (uint256 i; i < 2; ++i) {
            AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 2_400e6, 50);
            vm.prank(agent);
            vault.executeTrade(t);
            vm.warp(block.timestamp + 61);
            _prices(1e18, BTC, ETH);
        }
        AgentVault.Trade memory t3 = _trade(address(usdt), address(weth), 2_400e6, 50);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeTrade(t3);
        // next day it works again
        vm.warp(block.timestamp + 1 days);
        _prices(1e18, BTC, ETH);
        t3 = _trade(address(usdt), address(weth), 2_000e6, 50);
        vm.prank(agent);
        vault.executeTrade(t3);
    }

    function test_RevertTooSoon() public {
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 500e6, 50);
        vm.prank(agent);
        vault.executeTrade(t);
        t = _trade(address(usdt), address(weth), 500e6, 50);
        vm.prank(agent);
        vm.expectRevert(AgentVault.TooSoon.selector);
        vault.executeTrade(t);
    }

    function test_RevertSlippageTooLoose() public {
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 500e6, 500); // 5% > 1% cap
        vm.prank(agent);
        vm.expectRevert();
        vault.executeTrade(t);
    }

    function test_RevertVenueAndTokenNotAllowed() public {
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 500e6, 50);
        t.venue = address(new EvilVenue());
        vm.prank(agent);
        vm.expectRevert(AgentVault.VenueNotAllowed.selector);
        vault.executeTrade(t);

        MockERC20 junk = new MockERC20("junk", "J", 18);
        t = _trade(address(usdt), address(wbtc), 500e6, 50);
        t.tokenOut = address(junk);
        vm.prank(agent);
        vm.expectRevert(AgentVault.TokenNotAllowed.selector);
        vault.executeTrade(t);
    }

    function test_EvilVenueCannotStealOrFakeFill() public {
        vm.prank(owner);
        vault.setVenue(address(venue), false);
        EvilVenue ev = new EvilVenue();
        vm.prank(owner);
        vault.setVenue(address(ev), true); // owner (mistakenly) whitelists a bad venue
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 500e6, 50);
        t.venue = address(ev);
        vm.prank(agent);
        // the venue takes the input but delivers nothing -> vault reverts, funds untouched
        vm.expectRevert();
        vault.executeTrade(t);
        assertEq(usdt.balanceOf(address(vault)), 10_000e6);
    }

    function test_StaleOracleBlocksTrading_ButNotWithdrawal() public {
        vm.warp(block.timestamp + 2 hours);
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 500e6, 50);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeTrade(t);
        vm.prank(owner);
        vault.withdraw(address(usdt), 10_000e6, owner);
        assertEq(usdt.balanceOf(owner), 10_000e6);
    }

    function test_StrategyKillSwitch() public {
        vm.prank(owner);
        registry.setActive(sid, false);
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 500e6, 50);
        vm.prank(agent);
        vm.expectRevert(AgentVault.StrategyInactive.selector);
        vault.executeTrade(t);
    }

    // ------------------------------------------------------------ circuit breaker
    function test_DrawdownTrips() public {
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 2_500e6, 50);
        vm.prank(agent);
        vault.executeTrade(t);
        vm.warp(block.timestamp + 61);
        _prices(1e18, BTC * 80 / 100, ETH);
        vm.warp(block.timestamp + 61);
        _prices(1e18, BTC * 64 / 100, ETH);
        // NAV = 7500 + 2500*0.64*~0.998 ~= 9,096 -> dd ~9.0% (< 10%) ; one more step
        vm.warp(block.timestamp + 61);
        _prices(1e18, BTC * 52 / 100, ETH);
        vault.pokeCircuitBreaker(); // permissionless
        assertTrue(vault.halted());
        // trades blocked
        AgentVault.Trade memory t2 = _trade(address(usdt), address(weth), 100e6, 50);
        vm.warp(block.timestamp + 61);
        vm.prank(agent);
        vm.expectRevert(AgentVault.IsHalted.selector);
        vault.executeTrade(t2);
        // owner cannot resume without rebase while still breached
        vm.prank(owner);
        vm.expectRevert(AgentVault.StillBreached.selector);
        vault.resume(false);
        vm.prank(owner);
        vault.resume(true);
        assertFalse(vault.halted());
        // and can always withdraw while halted
        vm.prank(owner);
        vault.halt();
        uint256 bal = usdt.balanceOf(address(vault));
        vm.prank(owner);
        vault.withdraw(address(usdt), bal, owner);
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    function test_OracleMoveBound() public {
        vm.expectRevert();
        _prices(1e18, BTC * 2, ETH);
    }

    function test_WithdrawRebasesHwm() public {
        vm.prank(agent);
        vault.recordHold(keccak256("x"));
        assertEq(vault.highWaterMark(), 10_000e6);
        vm.prank(owner);
        vault.withdraw(address(usdt), 5_000e6, owner);
        assertEq(vault.highWaterMark(), 5_000e6);
        assertEq(vault.drawdownBps(), 0);
    }

    function test_FactoryForcesOwner() public {
        address[] memory none = new address[](0);
        AgentVault.Config memory c = AgentVault.Config({
            owner: stranger, agent: agent, baseAsset: address(usdt), oracle: address(oracle), registry: address(registry),
            strategyId: sid, tokens: none, venues: none,
            limits: AgentVault.Limits(1000, 1000, 1000, 100, 0, 3600)
        });
        vm.prank(owner);
        AgentVault v = factory.createVault(c);
        assertEq(v.owner(), owner);
        assertEq(factory.vaultsOf(owner).length, 2);
    }

    function test_BadLimitsRejected() public {
        vm.prank(owner);
        vm.expectRevert(AgentVault.BadLimits.selector);
        vault.setLimits(AgentVault.Limits(0, 1, 1, 1, 0, 1));
    }

    // ------------------------------------------------------------ fuzz: a trade can never lose more than the slippage cap
    function testFuzz_TradeLossBounded(uint256 amt, uint8 pick) public {
        amt = bound(amt, 1e6, 2_500e6);
        address tout = pick % 2 == 0 ? address(wbtc) : address(weth);
        AgentVault.Trade memory t = _trade(address(usdt), tout, amt, 100);
        uint256 navBefore = vault.nav();
        vm.prank(agent);
        vault.executeTrade(t);
        uint256 navAfter = vault.nav();
        // loss <= slippage cap (1%) of traded value + 1 wei rounding
        assertGe(navAfter + (amt * 100) / 10_000 + 2, navBefore);
    }

    function testFuzz_OwnerAlwaysWithdraws(uint256 amt) public {
        amt = bound(amt, 1, 10_000e6);
        vm.prank(owner);
        vault.halt();
        vm.warp(block.timestamp + 30 days); // oracle stale too
        vm.prank(owner);
        vault.withdraw(address(usdt), amt, owner);
        assertEq(usdt.balanceOf(owner), amt);
    }

    function test_LogChainMatchesEvents() public {
        vm.recordLogs();
        AgentVault.Trade memory t = _trade(address(usdt), address(wbtc), 1_000e6, 50);
        vm.prank(agent);
        vault.executeTrade(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = AgentVault.TradeExecuted.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(vault)) continue;
            (, address tin, address tout, uint256 spent, uint256 out,, uint256 navAfter,, uint256 ts, bytes32 head) =
                abi.decode(logs[i].data, (address, address, address, uint256, uint256, uint256, uint256, uint32, uint256, bytes32));
            // an independent verifier recomputes the chain from public event data only
            bytes32 expect = keccak256(abi.encode(bytes32(0), uint256(1), uint8(1), t.decisionHash, tin, tout, spent, out, navAfter, ts));
            assertEq(head, expect);
            assertEq(vault.logHead(), expect);
            found = true;
        }
        assertTrue(found);
    }
}
