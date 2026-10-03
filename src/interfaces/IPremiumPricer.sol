// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Pluggable premium pricer. A market can price premiums with the built-in `RiskCurve`, the
///         native ArcBook `CurveKernelPricer`, or an external source (e.g. a futarchy prediction
///         market) — without changing core buy/claim logic.
interface IPremiumPricer {
  function quote(bytes32 marketHash, uint256 coverNotional, uint256 newOutstanding, uint256 capacity)
    external
    view
    returns (uint256 premium);
}
