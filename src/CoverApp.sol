// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {AquaApp} from "@1inch/aqua/src/AquaApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IReserveHook} from "./interfaces/IReserveHook.sol";
import {ITrigger} from "./interfaces/ITrigger.sol";
import {IPremiumPricer} from "./interfaces/IPremiumPricer.sol";
import {RiskCurve} from "./libraries/RiskCurve.sol";
import {CoverNote} from "./CoverNote.sol";
import {SolventBook} from "./SolventBook.sol";

/// @title Airbag CoverApp
/// @notice Non-custodial, provably-solvent, parametric depeg cover on 1inch Aqua.
///         - Underwriters `ship` USDG virtual balances (reserve stays in their wallet, can earn yield).
///         - Buyers pay a risk-curve premium (`push`ed to the underwriter) and receive an ERC-6909
///           CoverNote (transferable, so cover is assignable).
///         - On a depeg the covered notional is `pull`ed from the underwriter to the note holder,
///           atomically. Per-market and (optional) aggregate SolventBook floors prevent overselling.
contract CoverApp is AquaApp {
  using SafeERC20 for IERC20;

  struct Market {
    address underwriter; // Aqua maker
    address asset; // insured + reserve + settlement token (e.g. USDG)
    address oracle; // price feed for `asset`
    uint256 pegPrice; // target price in oracle decimals (e.g. 1e8 for $1)
    uint16 depegBps; // triggers when price <= peg * (1e4 - depegBps) / 1e4
    uint16 maxUtilBps; // outstanding cover <= backing * maxUtilBps / 1e4 (solvency floor)
    uint32 oracleTimeout; // max oracle staleness (seconds)
    uint256 startRateWad; // risk curve: premium rate at 0% utilization (WAD)
    uint256 endRateWad; // risk curve: premium rate at 100% utilization (WAD)
    uint256 convexityWad; // risk curve: shape (1e18 linear, >1e18 convex)
    address trigger; // address(0) = built-in depeg (oracle band); else an external ITrigger product
    bytes32 salt;
  }

  struct Policy {
    bytes32 marketHash;
    uint256 coverNotional;
    uint64 expiry;
    bool claimed;
    address buyer;
    uint64 boughtAt;
    uint256 premium;
    uint256 paidOut;
  }

  uint256 internal constant BPS = 10_000;
  uint256 internal constant WAD = 1e18;
  /// @dev Risk-curve rates are ANNUAL: a policy pays rate(u) × notional × term / YEAR, like real cover.
  uint256 internal constant YEAR = 365 days;

  CoverNote public coverNote;
  SolventBook public solventBook; // optional aggregate floor; address(0) = per-market only
  address public immutable owner;

  mapping(bytes32 strategyHash => Market) public markets;
  mapping(bytes32 strategyHash => bool) public registered;
  mapping(bytes32 strategyHash => uint256 notional) public outstanding;
  mapping(uint256 policyId => Policy) public policies;
  mapping(address underwriter => IReserveHook) public reserveHook; // optional yield-JIT hook
  mapping(bytes32 strategyHash => address) public premiumPricer; // optional external pricer (else RiskCurve)
  uint256 public nextPolicyId;
  /// @notice Every registered market, so frontends/keepers enumerate state without log scans.
  bytes32[] public marketList;

  event MarketRegistered(bytes32 indexed strategyHash, address indexed underwriter, address indexed asset);
  event PolicyBought(
    uint256 indexed policyId,
    bytes32 indexed strategyHash,
    address indexed buyer,
    uint256 coverNotional,
    uint256 premium
  );
  event PolicyClaimed(uint256 indexed policyId, address indexed to, uint256 payout, uint256 price);
  event PolicyExpiredReleased(uint256 indexed policyId, bytes32 indexed strategyHash, uint256 coverNotional);

  error AlreadyInitialized();
  error NotOwner();
  error AlreadyRegistered();
  error NotUnderwriter();
  error UnknownMarket();
  error SolvencyFloorBreached(uint256 requested, uint256 available);
  error AggregateFloorBreached();
  error PolicyExpired();
  error PolicyNotExpired();
  error PolicyAlreadyClaimed();
  error NotNoteHolder();
  error StaleOracle();
  error NotDepegged(uint256 price, uint256 triggerPrice);
  error NotTriggered();
  error ZeroAmount();

  constructor(IAqua aqua, address _owner) AquaApp(aqua) {
    owner = _owner;
  }

  /// @notice One-time wiring of the CoverNote (deployed after CoverApp) and optional SolventBook.
  function initialize(CoverNote note, SolventBook book) external {
    if (msg.sender != owner) revert NotOwner();
    if (address(coverNote) != address(0)) revert AlreadyInitialized();
    coverNote = note;
    solventBook = book;
  }

  function setSolventBook(SolventBook book) external {
    if (msg.sender != owner) revert NotOwner();
    solventBook = book;
  }

  /// @notice Underwriter registers an optional yield-JIT reserve hook for their own maker address.
  function setReserveHook(IReserveHook hook) external {
    reserveHook[msg.sender] = hook;
  }

  /// @notice Underwriter sets an external premium pricer for their market (else built-in RiskCurve).
  function setPremiumPricer(bytes32 strategyHash, address pricer) external {
    if (msg.sender != markets[strategyHash].underwriter) revert NotUnderwriter();
    premiumPricer[strategyHash] = pricer;
  }

  // ── Underwriter
  // ──────────────────────────────────────────────────────────

  function registerMarket(Market calldata market) external returns (bytes32 strategyHash) {
    if (msg.sender != market.underwriter) revert NotUnderwriter();
    strategyHash = keccak256(abi.encode(market));
    if (registered[strategyHash]) revert AlreadyRegistered();
    // authenticates that the underwriter shipped exactly this strategy backing `market.asset`
    AQUA.safeBalances(market.underwriter, address(this), strategyHash, market.asset, market.asset);
    markets[strategyHash] = market;
    registered[strategyHash] = true;
    marketList.push(strategyHash);
    emit MarketRegistered(strategyHash, market.underwriter, market.asset);
  }

  // ── Views
  // ────────────────────────────────────────────────────────────────

  function backingOf(bytes32 strategyHash) public view returns (uint256 backing) {
    Market storage m = markets[strategyHash];
    (backing,) = AQUA.safeBalances(m.underwriter, address(this), strategyHash, m.asset, m.asset);
  }

  function capacityOf(bytes32 strategyHash) public view returns (uint256) {
    return backingOf(strategyHash) * markets[strategyHash].maxUtilBps / BPS;
  }

  /// @notice Premium for one year of `coverNotional` cover (the annual rate), at post-trade utilization.
  function quotePremium(bytes32 strategyHash, uint256 coverNotional) public view returns (uint256) {
    return quotePremiumFor(strategyHash, coverNotional, uint64(YEAR));
  }

  /// @notice Premium for `coverNotional` of cover over `duration` seconds: annual rate × term.
  function quotePremiumFor(bytes32 strategyHash, uint256 coverNotional, uint64 duration)
    public
    view
    returns (uint256)
  {
    uint256 capacity = capacityOf(strategyHash);
    if (capacity == 0) return 0;
    return _premium(strategyHash, coverNotional, outstanding[strategyHash] + coverNotional, capacity) * duration / YEAR;
  }

  /// @dev Premium via the market's external pricer if set, else the built-in RiskCurve.
  function _premium(bytes32 strategyHash, uint256 coverNotional, uint256 newOutstanding, uint256 capacity)
    internal
    view
    returns (uint256)
  {
    address p = premiumPricer[strategyHash];
    if (p != address(0)) return IPremiumPricer(p).quote(strategyHash, coverNotional, newOutstanding, capacity);
    Market storage m = markets[strategyHash];
    return RiskCurve.premium(coverNotional, m.startRateWad, m.endRateWad, m.convexityWad, newOutstanding * WAD / capacity);
  }

  function marketCount() external view returns (uint256) {
    return marketList.length;
  }

  function solvency(bytes32 strategyHash)
    external
    view
    returns (uint256 backing, uint256 covered, uint256 utilizationBps)
  {
    backing = backingOf(strategyHash);
    covered = outstanding[strategyHash];
    utilizationBps = backing == 0 ? 0 : covered * BPS / backing;
  }

  // ── Buyer
  // ────────────────────────────────────────────────────────────────

  /// @notice Buy cover, minting the CoverNote to msg.sender.
  function buyPolicy(bytes32 strategyHash, uint256 coverNotional, uint64 duration) external returns (uint256 policyId) {
    return _buy(strategyHash, coverNotional, duration, msg.sender);
  }

  /// @notice Buy cover, minting the CoverNote to `to` (used by the CoverRouter for routed buys).
  ///         Premium is always pulled from msg.sender.
  function buyPolicyFor(bytes32 strategyHash, uint256 coverNotional, uint64 duration, address to)
    external
    returns (uint256 policyId)
  {
    return _buy(strategyHash, coverNotional, duration, to);
  }

  function _buy(bytes32 strategyHash, uint256 coverNotional, uint64 duration, address to)
    internal
    returns (uint256 policyId)
  {
    if (!registered[strategyHash]) revert UnknownMarket();
    if (coverNotional == 0 || duration == 0) revert ZeroAmount();
    Market storage m = markets[strategyHash];

    uint256 capacity = capacityOf(strategyHash);
    uint256 newOutstanding = outstanding[strategyHash] + coverNotional;
    if (newOutstanding > capacity) revert SolvencyFloorBreached(newOutstanding, capacity);

    // Optional aggregate (cross-market) floor from the attestor-fed SolventBook.
    if (address(solventBook) != address(0)) {
      if (solventBook.headroom(m.underwriter, m.asset) < coverNotional) revert AggregateFloorBreached();
    }

    uint256 premium = _premium(strategyHash, coverNotional, newOutstanding, capacity) * duration / YEAR;

    // Pull premium from buyer, push it into the underwriter's Aqua reserve.
    IERC20(m.asset).safeTransferFrom(msg.sender, address(this), premium);
    IERC20(m.asset).forceApprove(address(AQUA), premium);
    AQUA.push(m.underwriter, address(this), strategyHash, m.asset, premium);

    outstanding[strategyHash] = newOutstanding;
    policyId = nextPolicyId++;
    policies[policyId] = Policy({
      marketHash: strategyHash, 
      coverNotional: coverNotional, 
      expiry: uint64(block.timestamp) + duration,
      claimed: false,
      buyer: to,
      boughtAt: uint64(block.timestamp),
      premium: premium,
      paidOut: 0
    });
    coverNote.mint(to, policyId, 1);
    emit PolicyBought(policyId, strategyHash, to, coverNotional, premium);
  }

  // ── Claim
  // ────────────────────────────────────────────────────────────────

  /// @notice Claim if the insured event has occurred (built-in depeg, or an external trigger
  ///         product). Pays the CoverNote holder atomically from the underwriter's reserve.
  function claim(uint256 policyId) external returns (uint256 payout) {
    if (coverNote.balanceOf(msg.sender, policyId) == 0) revert NotNoteHolder();
    return _settle(policyId, msg.sender);
  }

  /// @notice Auto-payout: anyone (a keeper bot, a friend, the underwriter) can fire a triggered
  ///         policy, and the payout goes to whoever holds the note right now. The airbag deploys
  ///         itself — the insured never has to show up to claim.
  function payout(uint256 policyId) external returns (uint256) {
    address holder = coverNote.holderOf(policyId);
    if (holder == address(0)) revert NotNoteHolder();
    return _settle(policyId, holder);
  }

  function _settle(uint256 policyId, address holder) internal returns (uint256 amount) {
    Policy storage p = policies[policyId];
    if (p.claimed) revert PolicyAlreadyClaimed();
    if (block.timestamp > p.expiry) revert PolicyExpired();

    Market storage m = markets[p.marketHash];
    uint256 payoutBps = _evaluateTrigger(m, p.marketHash, policyId);

    // effects before interaction (release the full reserved notional; pay `payoutBps` of it)
    amount = p.coverNotional * payoutBps / BPS;
    p.claimed = true;
    p.paidOut = amount;
    outstanding[p.marketHash] -= p.coverNotional;
    coverNote.burn(holder, policyId, 1);

    // yield-JIT: let a registered reserve hook top up liquid balance before the pull
    IReserveHook hook = reserveHook[m.underwriter];
    if (address(hook) != address(0)) hook.onBeforePull(m.asset, amount);

    // pull payout from the underwriter's wallet to the note holder (atomic; reverts if unbacked)
    if (amount > 0) AQUA.pull(m.underwriter, p.marketHash, m.asset, amount, holder);
    emit PolicyClaimed(policyId, holder, amount, payoutBps);
  }

  // ── Expiry
  // ───────────────────────────────────────────────────────────────

  /// @notice Settle a policy that lapsed without a claim: releases its reserved notional so the
  ///         underwriter's capacity frees up (they keep the premium). Permissionless — anyone
  ///         (a keeper, the underwriter) can call it once the policy is past expiry.
  function expire(uint256 policyId) external {
    Policy storage p = policies[policyId];
    if (p.coverNotional == 0) revert UnknownMarket();
    if (p.claimed) revert PolicyAlreadyClaimed();
    if (block.timestamp <= p.expiry) revert PolicyNotExpired();

    p.claimed = true; // settled; the lapsed note can no longer claim
    outstanding[p.marketHash] -= p.coverNotional;
    emit PolicyExpiredReleased(policyId, p.marketHash, p.coverNotional);
  }

  /// @dev Returns the payout fraction (bps) if triggered, else reverts.
  function _evaluateTrigger(Market storage m, bytes32 marketHash, uint256 policyId)
    internal
    view
    returns (uint256 payoutBps)
  {
    if (m.trigger == address(0)) {
      // built-in depeg: pay in full when the oracle price crosses the band
      (uint256 price, uint256 updatedAt) = IPriceOracle(m.oracle).latestPrice();
      if (price == 0 || block.timestamp - updatedAt > m.oracleTimeout) revert StaleOracle();
      uint256 triggerPrice = m.pegPrice * (BPS - m.depegBps) / BPS;
      if (price > triggerPrice) revert NotDepegged(price, triggerPrice);
      return BPS;
    }
    (bool ok, uint256 bps) = ITrigger(m.trigger).check(marketHash, policyId);
    if (!ok) revert NotTriggered();
    return bps > BPS ? BPS : bps;
  }
}
