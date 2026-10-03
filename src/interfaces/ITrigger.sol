// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Pluggable parametric trigger. A market can point at an external trigger contract instead
///         of the built-in depeg check, so the same CoverApp underwrites many products (IL cover,
///         slippage/MEV refund, RWA gap, binary events, …) without changing core claim logic.
interface ITrigger {
  /// @param marketHash The market (strategyHash) the policy belongs to.
  /// @param policyId    The policy being claimed.
  /// @return triggered  Whether the insured event has occurred.
  /// @return payoutBps  Fraction of the covered notional to pay (<= 10_000 = full).
  function check(bytes32 marketHash, uint256 policyId) external view returns (bool triggered, uint256 payoutBps);
}
