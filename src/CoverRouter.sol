// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CoverApp} from "./CoverApp.sol";

/// @title CoverRouter
/// @notice The competitive risk-curve order book: cover is sourced across many underwriters'
///         markets in one atomic route. An off-chain deterministic solver walks each market's risk
///         curve and assembles the cheapest legs; this batch executor fills them atomically with a
///         route-level premium cap, refunding any unspent premium. Buying cover becomes a market
///         for risk rather than an admin-set rate. (Mirrors ArcBook's solver + batch executor.)
contract CoverRouter is ReentrancyGuard {
  using SafeERC20 for IERC20;

  struct Leg {
    bytes32 strategyHash;
    uint256 coverNotional;
  }

  CoverApp public immutable cover;

  event RouteFilled(address indexed buyer, address indexed to, uint256 totalCover, uint256 totalPremium, uint256 legs);

  error EmptyRoute();
  error DeadlineExpired();
  error PremiumExceedsMax(uint256 spent, uint256 max);

  constructor(CoverApp _cover) {
    cover = _cover;
  }

  /// @notice Quote the total annual premium for a route at current utilization (per-leg, additive).
  function quoteRoute(Leg[] calldata legs) external view returns (uint256 totalCover, uint256 totalPremium) {
    return quoteRouteFor(legs, 365 days);
  }

  /// @notice Quote the total premium for a route over `duration` seconds.
  function quoteRouteFor(Leg[] calldata legs, uint64 duration)
    public
    view
    returns (uint256 totalCover, uint256 totalPremium)
  {
    for (uint256 i; i < legs.length; ++i) {
      totalCover += legs[i].coverNotional;
      totalPremium += cover.quotePremiumFor(legs[i].strategyHash, legs[i].coverNotional, duration);
    }
  }

  /// @notice Execute a route atomically: buy each leg, cap total premium, refund the remainder.
  /// @param legs Solver-assembled legs (cheapest markets first).
  /// @param asset The common settlement token (e.g. USDG) all legs are priced/paid in.
  /// @param maxTotalPremium Route-level premium cap (slippage protection).
  /// @param to Recipient of the CoverNotes.
  function buyRoute(
    Leg[] calldata legs,
    address asset,
    uint256 maxTotalPremium,
    uint64 duration,
    address to,
    uint256 deadline
  ) external nonReentrant returns (uint256[] memory policyIds, uint256 totalPremium) {
    if (legs.length == 0) revert EmptyRoute();
    if (block.timestamp > deadline) revert DeadlineExpired();

    IERC20(asset).safeTransferFrom(msg.sender, address(this), maxTotalPremium);
    IERC20(asset).forceApprove(address(cover), maxTotalPremium);

    policyIds = new uint256[](legs.length);
    uint256 totalCover;
    for (uint256 i; i < legs.length; ++i) {
      policyIds[i] = cover.buyPolicyFor(legs[i].strategyHash, legs[i].coverNotional, duration, to);
      totalCover += legs[i].coverNotional;
    }

    // Refund unspent premium; the amount the CoverApp pulled is the true total premium.
    uint256 leftover = IERC20(asset).balanceOf(address(this));
    totalPremium = maxTotalPremium - leftover;
    if (totalPremium > maxTotalPremium) revert PremiumExceedsMax(totalPremium, maxTotalPremium);
    IERC20(asset).forceApprove(address(cover), 0);
    if (leftover > 0) IERC20(asset).safeTransfer(msg.sender, leftover);

    emit RouteFilled(msg.sender, to, totalCover, totalPremium, legs.length);
  }
}
