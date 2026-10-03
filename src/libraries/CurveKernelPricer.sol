// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
  AlphaWad,
  AmountWad,
  CurveConfig,
  CurveQuote,
  CurveSide,
  CurveState,
  NativeCurve,
  PriceWad,
  RateWad,
  UnitlessWad
} from "@arcbook/types/CurveTypes.sol";
import {CurveCompiler} from "@arcbook/libraries/CurveCompiler.sol";
import {CurveMath} from "@arcbook/libraries/CurveMath.sol";

/// @title CurveKernelPricer
/// @notice Prices a premium using ArcBook's executable curve kernel (`CurveMath`) instead of the
///         lightweight solady `RiskCurve`. The premium schedule is a real bounded bonding curve:
///         cover-notional consumed (base) is exact-out, premium (quote) is the integral along the
///         curve, with maker-favorable rounding and a monotonicity guard — the "native curve" that
///         the SwapVM order-book path settles through. Capacity is the curve's reserve (`yInt`),
///         so premiums rise as the fund fills, by construction.
library CurveKernelPricer {
  error AmountTooLarge();

  function _toWad128(uint256 x) private pure returns (uint128) {
    if (x > type(uint128).max) revert AmountTooLarge();
    return uint128(x);
  }

  /// @param coverNotionalWad Cover being bought (WAD).
  /// @param capacityWad      Total cover capacity = backing * maxUtil (WAD) — the curve reserve.
  /// @param outstandingWad   Cover already sold (WAD).
  /// @param startPriceWad    Premium rate per cover unit at 0% utilization (WAD, < endPrice).
  /// @param endPriceWad      Premium rate per cover unit at 100% utilization (WAD).
  /// @param alphaWad         Curve shape (0 = geometric).
  /// @return premiumWad The premium (WAD) — the integral along the curve for `coverNotionalWad`.
  function premium(
    uint256 coverNotionalWad,
    uint256 capacityWad,
    uint256 outstandingWad,
    uint128 startPriceWad,
    uint128 endPriceWad,
    int128 alphaWad
  ) internal pure returns (uint256 premiumWad) {
    CurveConfig memory cfg = CurveConfig({
      startPrice: PriceWad.wrap(startPriceWad),
      endPrice: PriceWad.wrap(endPriceWad),
      alpha: AlphaWad.wrap(alphaWad),
      initialReserve: AmountWad.wrap(_toWad128(capacityWad)),
      mu: UnitlessWad.wrap(0),
      kappa: RateWad.wrap(0)
    });
    // derive canonical mu/kappa, then compile to the native curve
    cfg = CurveCompiler.derive(cfg, CurveSide.Sell);
    NativeCurve memory nc = CurveCompiler.compile(cfg, CurveSide.Sell);

    CurveState memory st = CurveState({
      y: AmountWad.wrap(_toWad128(capacityWad - outstandingWad)), yInt: AmountWad.wrap(_toWad128(capacityWad))
    });

    CurveQuote memory q =
      CurveMath.quoteExactOutput(nc, st, CurveSide.Sell, AmountWad.wrap(_toWad128(coverNotionalWad)));
    premiumWad = uint256(AmountWad.unwrap(q.amountInWad));
  }
}
