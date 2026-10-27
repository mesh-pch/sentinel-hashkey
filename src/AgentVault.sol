// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IVenue} from "./interfaces/IVenue.sol";
import {StrategyRegistry} from "./StrategyRegistry.sol";

/// @title AgentVault
/// @notice A non-custodial vault that lets an AI agent *trade but never withdraw*, inside hard on-chain risk limits.
///         Every decision (trade or hold) is committed on-chain as a `decisionHash` and folded into a hash-chained
///         log (`logHead`) so anybody can verify, off-chain, that the published reasoning is what the agent acted on.
///
///         Enforced on-chain, per trade:
///           - agent only; vault not halted; strategy still active in the StrategyRegistry
///           - venue + tokens whitelisted by the owner
///           - trade size <= maxTradeBps of NAV, rolling-24h turnover <= maxDailyVolumeBps of NAV, min interval
///           - `minAmountOut` must be at least the oracle-fair output minus maxSlippageBps (no "accept any price")
///           - fills are measured from the vault's own balances (a lying venue cannot fake output / overspend)
///           - circuit breaker: if NAV falls maxDrawdownBps below its high-water mark the vault halts itself
///             (anyone can poke it); only the owner can resume.
///         The owner can withdraw at any time, even when halted or when the oracle is stale.
contract AgentVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types
    struct Limits {
        uint16 maxTradeBps; // max single trade size, % of NAV in bps
        uint16 maxDailyVolumeBps; // max rolling-24h traded notional, % of NAV in bps
        uint16 maxDrawdownBps; // circuit breaker threshold vs high-water mark
        uint16 maxSlippageBps; // max deviation from oracle-fair price
        uint32 minIntervalSec; // min seconds between two trades
        uint32 maxOracleAge; // max age of any oracle price used, seconds
    }

    struct Trade {
        address venue;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes32 decisionHash; // keccak256 of the canonical off-chain decision record
    }

    // ------------------------------------------------------------------ errors
    error NotAgent();
    error NotOwnerOrAgent();
    error IsHalted();
    error NotHalted();
    error StrategyInactive();
    error VenueNotAllowed();
    error TokenNotAllowed();
    error ZeroAmount();
    error TooSoon();
    error TradeTooLarge(uint256 tradeValue, uint256 maxValue);
    error DailyVolumeExceeded(uint256 volume, uint256 maxVolume);
    error SlippageTooLoose(uint256 minAmountOut, uint256 requiredFloor);
    error InsufficientOutput(uint256 got, uint256 wanted);
    error Overspent(uint256 spent, uint256 allowed);
    error DrawdownBreached();
    error StaleOracle(address token);
    error BadLimits();
    error TooManyTokens();
    error StillBreached();

    // ------------------------------------------------------------------ events
    event TradeExecuted(
        uint256 indexed id,
        bytes32 indexed decisionHash,
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 navBefore,
        uint256 navAfter,
        uint32 strategyVersion,
        uint256 timestamp,
        bytes32 logHead
    );
    event HoldRecorded(
        uint256 indexed id, bytes32 indexed decisionHash, uint256 nav, uint256 timestamp, bytes32 logHead
    );
    event CircuitBreakerTripped(uint256 nav, uint256 highWaterMark, uint256 drawdownBps);
    event Halted(address indexed by);
    event Resumed(uint256 highWaterMark);
    event LimitsUpdated(Limits limits);
    event AgentUpdated(address indexed agent);
    event StrategyUpdated(uint256 indexed strategyId);
    event VenueSet(address indexed venue, bool allowed);
    event TokenAdded(address indexed token);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ state
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_TOKENS = 12;

    address public immutable baseAsset;
    IPriceOracle public immutable oracle;
    StrategyRegistry public immutable registry;
    uint8 private immutable _baseDecimals;

    address public agent;
    uint256 public strategyId;
    Limits public limits;

    address[] private _tokens;
    mapping(address => bool) public isTradable;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => bool) public allowedVenue;

    bool public halted;
    uint256 public highWaterMark; // in base-asset units
    uint256 public lastTradeAt;
    uint256 public dayStart;
    uint256 public dayVolume; // base-asset units

    uint256 public logCount;
    bytes32 public logHead;

    struct Config {
        address owner;
        address agent;
        address baseAsset;
        address oracle;
        address registry;
        uint256 strategyId;
        address[] tokens; // tradable tokens besides the base asset
        address[] venues;
        Limits limits;
    }

    constructor(Config memory c) Ownable(c.owner) {
        baseAsset = c.baseAsset;
        oracle = IPriceOracle(c.oracle);
        registry = StrategyRegistry(c.registry);
        _baseDecimals = IERC20Metadata(c.baseAsset).decimals();
        agent = c.agent;
        strategyId = c.strategyId;
        _setLimits(c.limits);
        _addToken(c.baseAsset);
        for (uint256 i; i < c.tokens.length; ++i) {
            _addToken(c.tokens[i]);
        }
        for (uint256 i; i < c.venues.length; ++i) {
            allowedVenue[c.venues[i]] = true;
            emit VenueSet(c.venues[i], true);
        }
        emit AgentUpdated(c.agent);
        emit StrategyUpdated(c.strategyId);
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    // ------------------------------------------------------------------ owner controls
    function setAgent(address newAgent) external onlyOwner {
        agent = newAgent;
        emit AgentUpdated(newAgent);
    }

    function setStrategy(uint256 id) external onlyOwner {
        strategyId = id;
        emit StrategyUpdated(id);
    }

    function setLimits(Limits calldata l) external onlyOwner {
        _setLimits(l);
    }

    function setVenue(address venue, bool allowed) external onlyOwner {
        allowedVenue[venue] = allowed;
        emit VenueSet(venue, allowed);
    }

    function addToken(address token) external onlyOwner {
        _addToken(token);
    }

    /// @notice Deposit base asset (owner only so accounting stays clean; anybody can still donate by transfer).
    function deposit(uint256 amount) external onlyOwner {
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), amount);
        if (highWaterMark != 0) highWaterMark += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw any token at any time. Never blocked by `halted`, limits, the agent or the oracle.
    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        (bool okBefore, uint256 navBefore) = _tryNav();
        IERC20(token).safeTransfer(to, amount);
        if (okBefore && navBefore != 0) {
            (bool okAfter, uint256 navAfter) = _tryNav();
            highWaterMark = okAfter ? (highWaterMark * navAfter) / navBefore : 0;
        } else {
            highWaterMark = 0; // re-based on the next NAV read
        }
        emit Withdrawn(token, to, amount);
    }

    function halt() external {
        if (msg.sender != owner() && msg.sender != agent) revert NotOwnerOrAgent();
        halted = true;
        emit Halted(msg.sender);
    }

    /// @param rebase if true the high-water mark is reset to the current NAV (owner accepts the loss);
    ///        if false the vault only resumes when NAV is back within the drawdown limit.
    function resume(bool rebase) external onlyOwner {
        if (!halted) revert NotHalted();
        uint256 n = nav();
        if (rebase) {
            highWaterMark = n;
        } else if (_breached(n)) {
            revert StillBreached();
        }
        halted = false;
        emit Resumed(highWaterMark);
    }

    // ------------------------------------------------------------------ agent actions
    function executeTrade(Trade calldata t) external onlyAgent nonReentrant returns (uint256 amountOut) {
        Limits memory L = limits;
        uint256 navBefore = _preTrade(t, L);

        // --- execute, measuring real balance deltas
        uint256 inBefore = IERC20(t.tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(t.tokenOut).balanceOf(address(this));
        IERC20(t.tokenIn).forceApprove(t.venue, t.amountIn);
        IVenue(t.venue).swap(t.tokenIn, t.tokenOut, t.amountIn, t.minAmountOut, address(this));
        IERC20(t.tokenIn).forceApprove(t.venue, 0);
        uint256 inAfter = IERC20(t.tokenIn).balanceOf(address(this));
        uint256 spent = inBefore > inAfter ? inBefore - inAfter : 0;
        if (spent > t.amountIn) revert Overspent(spent, t.amountIn);
        uint256 outAfter = IERC20(t.tokenOut).balanceOf(address(this));
        amountOut = outAfter > outBefore ? outAfter - outBefore : 0;
        if (amountOut < t.minAmountOut) revert InsufficientOutput(amountOut, t.minAmountOut);

        lastTradeAt = block.timestamp;
        uint256 navAfter = _nav(L.maxOracleAge);
        _syncHwm(navAfter);
        _trip(navAfter);
        _logTrade(t, spent, amountOut, navBefore, navAfter);
    }

    /// @dev all pre-trade validation; returns NAV before the trade
    function _preTrade(Trade calldata t, Limits memory L) private returns (uint256 navBefore) {
        if (halted) revert IsHalted();
        if (!registry.isActive(strategyId)) revert StrategyInactive();
        if (!allowedVenue[t.venue]) revert VenueNotAllowed();
        if (!isTradable[t.tokenIn] || !isTradable[t.tokenOut] || t.tokenIn == t.tokenOut) revert TokenNotAllowed();
        if (t.amountIn == 0) revert ZeroAmount();
        if (block.timestamp < lastTradeAt + L.minIntervalSec) revert TooSoon();

        navBefore = _nav(L.maxOracleAge);
        _syncHwm(navBefore);
        if (_breached(navBefore)) revert DrawdownBreached();

        // size limits
        uint256 tradeValue = _value(t.tokenIn, t.amountIn, L.maxOracleAge);
        uint256 maxValue = (navBefore * L.maxTradeBps) / BPS;
        if (tradeValue > maxValue) revert TradeTooLarge(tradeValue, maxValue);
        if (block.timestamp >= dayStart + 1 days) {
            dayStart = block.timestamp;
            dayVolume = 0;
        }
        dayVolume += tradeValue;
        uint256 maxVolume = (navBefore * L.maxDailyVolumeBps) / BPS;
        if (dayVolume > maxVolume) revert DailyVolumeExceeded(dayVolume, maxVolume);

        // price protection: the agent must commit to a minOut no looser than oracle-fair minus maxSlippage
        uint256 floorOut =
            (_fairOut(t.tokenIn, t.tokenOut, t.amountIn, L.maxOracleAge) * (BPS - L.maxSlippageBps)) / BPS;
        if (t.minAmountOut < floorOut) revert SlippageTooLoose(t.minAmountOut, floorOut);
    }

    function _logTrade(Trade calldata t, uint256 spent, uint256 amountOut, uint256 navBefore, uint256 navAfter) private {
        uint256 id = ++logCount;
        bytes32 head = keccak256(
            abi.encode(
                logHead, id, uint8(1), t.decisionHash, t.tokenIn, t.tokenOut, spent, amountOut, navAfter, block.timestamp
            )
        );
        logHead = head;
        emit TradeExecuted(
            id,
            t.decisionHash,
            t.venue,
            t.tokenIn,
            t.tokenOut,
            spent,
            amountOut,
            navBefore,
            navAfter,
            registry.versionOf(strategyId),
            block.timestamp,
            head
        );
    }

    /// @notice Commit a "do nothing" decision on-chain (with an NAV snapshot) so the log shows the agent's full behaviour.
    function recordHold(bytes32 decisionHash) external onlyAgent {
        uint256 n = _nav(limits.maxOracleAge);
        _syncHwm(n);
        _trip(n);
        uint256 id = ++logCount;
        bytes32 head = keccak256(abi.encode(logHead, id, uint8(0), decisionHash, n, block.timestamp));
        logHead = head;
        emit HoldRecorded(id, decisionHash, n, block.timestamp, head);
    }

    /// @notice Permissionless keeper hook: halts the vault if the drawdown limit is breached.
    function pokeCircuitBreaker() external {
        uint256 n = _nav(limits.maxOracleAge);
        _syncHwm(n);
        _trip(n);
    }

    // ------------------------------------------------------------------ views
    function nav() public view returns (uint256) {
        return _nav(limits.maxOracleAge);
    }

    function drawdownBps() external view returns (uint256) {
        uint256 n = nav();
        if (highWaterMark == 0 || n >= highWaterMark) return 0;
        return ((highWaterMark - n) * BPS) / highWaterMark;
    }

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function balances() external view returns (address[] memory toks, uint256[] memory bals) {
        toks = _tokens;
        bals = new uint256[](toks.length);
        for (uint256 i; i < toks.length; ++i) {
            bals[i] = IERC20(toks[i]).balanceOf(address(this));
        }
    }

    // ------------------------------------------------------------------ internals
    function _setLimits(Limits memory l) private {
        if (
            l.maxTradeBps == 0 || l.maxTradeBps > BPS || l.maxDailyVolumeBps > 10 * BPS || l.maxDrawdownBps == 0
                || l.maxDrawdownBps > BPS || l.maxSlippageBps > BPS || l.maxOracleAge == 0
        ) revert BadLimits();
        limits = l;
        emit LimitsUpdated(l);
    }

    function _addToken(address token) private {
        if (isTradable[token]) return;
        if (_tokens.length >= MAX_TOKENS) revert TooManyTokens();
        isTradable[token] = true;
        tokenDecimals[token] = IERC20Metadata(token).decimals();
        _tokens.push(token);
        emit TokenAdded(token);
    }

    function _tryNav() private view returns (bool ok, uint256 n) {
        try this.nav() returns (uint256 v) {
            return (true, v);
        } catch {
            return (false, 0);
        }
    }

    function _price(address token, uint32 maxAge) private view returns (uint256 p) {
        uint256 updatedAt;
        (p, updatedAt) = oracle.getPrice(token);
        if (p == 0 || updatedAt + maxAge < block.timestamp) revert StaleOracle(token);
    }

    /// @dev value of `amount` of `token` expressed in base-asset units
    function _value(address token, uint256 amount, uint32 maxAge) private view returns (uint256) {
        if (token == baseAsset) return amount;
        uint256 pT = _price(token, maxAge);
        uint256 pB = _price(baseAsset, maxAge);
        return (amount * pT * (10 ** _baseDecimals)) / (pB * (10 ** tokenDecimals[token]));
    }

    function _fairOut(address tokenIn, address tokenOut, uint256 amountIn, uint32 maxAge) private view returns (uint256) {
        uint256 pIn = _price(tokenIn, maxAge);
        uint256 pOut = _price(tokenOut, maxAge);
        return (amountIn * pIn * (10 ** tokenDecimals[tokenOut])) / (pOut * (10 ** tokenDecimals[tokenIn]));
    }

    function _nav(uint32 maxAge) private view returns (uint256 total) {
        uint256 len = _tokens.length;
        for (uint256 i; i < len; ++i) {
            address tk = _tokens[i];
            uint256 bal = IERC20(tk).balanceOf(address(this));
            if (bal != 0) total += _value(tk, bal, maxAge);
        }
    }

    function _syncHwm(uint256 n) private {
        if (n > highWaterMark) highWaterMark = n;
    }

    function _breached(uint256 n) private view returns (bool) {
        uint256 hwm = highWaterMark;
        if (hwm == 0 || n >= hwm) return false;
        return ((hwm - n) * BPS) / hwm >= limits.maxDrawdownBps;
    }

    function _trip(uint256 n) private {
        if (!halted && _breached(n)) {
            halted = true;
            emit CircuitBreakerTripped(n, highWaterMark, ((highWaterMark - n) * BPS) / highWaterMark);
            emit Halted(address(this));
        }
    }
}
