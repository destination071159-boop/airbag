// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveKernelPricer} from "../src/libraries/CurveKernelPricer.sol";

/// @notice Proves the vendored ArcBook CurveMath kernel prices a premium (native executable curve).
contract CurveKernelPricerTest is Test {
  uint256 constant CAPACITY = 800_000e18;
  uint128 constant START = 0.01e18; // 1% at 0% utilization
  uint128 constant END = 0.1e18; // 10% at 100% utilization
  int128 constant ALPHA = 0; // geometric

  function test_prices_and_rises_with_utilization() public pure {
    uint256 cover = 10_000e18;
    uint256 pLow = CurveKernelPricer.premium(cover, CAPACITY, 0, START, END, ALPHA);
    uint256 pMid = CurveKernelPricer.premium(cover, CAPACITY, 400_000e18, START, END, ALPHA);
    uint256 pHigh = CurveKernelPricer.premium(cover, CAPACITY, 700_000e18, START, END, ALPHA);

    assertGt(pLow, 0, "prices");
    assertGt(pMid, pLow, "rises with utilization");
    assertGt(pHigh, pMid, "keeps rising");
    // premium for 10k cover is bounded by ~end rate * cover (10%)
    assertLt(pHigh, 2000e18, "bounded near end rate");
  }
}
