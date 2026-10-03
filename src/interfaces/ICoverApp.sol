// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Thin interface to the Airbag CoverApp (deployed in the core unit on Aqua). The hook and
///         the CoverApp are separate compilation/deploy units that interoperate on-chain.
interface ICoverApp {
  function buyPolicyFor(bytes32 strategyHash, uint256 coverNotional, uint64 duration, address to)
    external
    returns (uint256 policyId);

  function quotePremium(bytes32 strategyHash, uint256 coverNotional) external view returns (uint256);
}
