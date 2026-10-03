// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title RiskCurve
/// @notice A bounded, monotonic premium curve: premium rises with utilization along a shaped path
///         between two hard rate bounds. This is Airbag's own risk-curve primitive, inspired by
///         ArcBook's bounded executable curves (the ArcBook `CurveMath` kernel is vendored under
///         `src/curve` and used by the SwapVM order-book path).
/// @dev All rates are WAD (1e18) fractions of covered notional. `convexityWad` shapes the curve:
///      1e18 = linear, >1e18 = convex (stays cheap, spikes near capacity), <1e18 = concave.
///      The curve is monotonic non-decreasing in utilization, so premiums can only rise as the
///      fund fills — the scarcity/solvency skew, enforced by the math.
library RiskCurve {
  uint256 internal constant WAD = 1e18;

  error EndBelowStart(uint256 startRateWad, uint256 endRateWad);

  /// @param startRateWad Premium rate at 0% utilization (the cheap bound).
  /// @param endRateWad   Premium rate at 100% utilization (the expensive bound). Must be >= start.
  /// @param convexityWad Curve shape exponent (1e18 = linear).
  /// @param utilWad      Utilization in WAD (covered / capacity), clamped to [0, 1e18].
  /// @return rateWad The premium rate at that utilization.
  function premiumRate(uint256 startRateWad, uint256 endRateWad, uint256 convexityWad, uint256 utilWad)
    internal
    pure
    returns (uint256 rateWad)
  {
    if (endRateWad < startRateWad) revert EndBelowStart(startRateWad, endRateWad);
    if (utilWad == 0) return startRateWad;
    if (utilWad >= WAD) return endRateWad;

    // t^k  (t in (0,1), k > 0)  -> value in (0,1); solady powWad works in WAD signed space.
    uint256 shaped = uint256(FixedPointMathLib.powWad(int256(utilWad), int256(convexityWad)));
    return startRateWad + FixedPointMathLib.mulWad(endRateWad - startRateWad, shaped);
  }

  /// @notice Premium for buying `coverNotional` when the market is at `newUtilWad` post-trade.
  /// @dev Prices at the post-trade utilization (maker-favorable — premium reflects the capacity the
  ///      purchase consumes), keeping the fund compensated as it fills.
  function premium(
    uint256 coverNotional,
    uint256 startRateWad,
    uint256 endRateWad,
    uint256 convexityWad,
    uint256 newUtilWad
  ) internal pure returns (uint256) {
    return FixedPointMathLib.mulWad(coverNotional, premiumRate(startRateWad, endRateWad, convexityWad, newUtilWad));
  }
}
