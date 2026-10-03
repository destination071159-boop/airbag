// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITrigger} from "../interfaces/ITrigger.sol";

/// @notice Source of realized slippage/MEV loss for a policy (written by the v4 afterSwap hook or a
///         keeper that compares executed price to a reference/oracle price).
interface ISlippageSource {
  function realizedSlippageBps(bytes32 marketHash, uint256 policyId) external view returns (uint256);
}

/// @title SlippageRefundTrigger
/// @notice MEV / slippage-refund cover: pays a swapper when their realized slippage exceeded a
///         configured threshold. Proportional payout = the realized slippage in bps (capped at BPS by
///         the CoverApp). Plug into a CoverApp market via Market.trigger.
contract SlippageRefundTrigger is ITrigger {
  ISlippageSource public immutable source;
  mapping(bytes32 marketHash => uint256) public thresholdBps;

  event Configured(bytes32 indexed marketHash, uint256 thresholdBps);

  constructor(ISlippageSource _source) {
    source = _source;
  }

  function configure(bytes32 marketHash, uint256 _thresholdBps) external {
    thresholdBps[marketHash] = _thresholdBps;
    emit Configured(marketHash, _thresholdBps);
  }

  function check(bytes32 marketHash, uint256 policyId) external view returns (bool triggered, uint256 payoutBps) {
    uint256 thr = thresholdBps[marketHash];
    if (thr == 0) return (false, 0);
    uint256 slip = source.realizedSlippageBps(marketHash, policyId);
    if (slip <= thr) return (false, 0);
    return (true, slip); // refund proportional to slippage suffered
  }
}
