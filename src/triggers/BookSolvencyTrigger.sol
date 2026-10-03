// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITrigger} from "../interfaces/ITrigger.sol";
import {SolventBook} from "../SolventBook.sol";

/// @title BookSolvencyTrigger
/// @notice "Solvency insurance for Aqua books" (meta cover): pays out when an underwriter's book goes
///         under-backed (backing < outstanding) per the attestor-fed SolventBook. Payout is
///         proportional to the shortfall — insuring the shared-liquidity layer, through the
///         shared-liquidity layer. Plug into a CoverApp market via Market.trigger.
contract BookSolvencyTrigger is ITrigger {
  struct Cfg {
    address underwriter;
    address asset;
    bool set;
  }

  uint256 internal constant BPS = 10_000;

  SolventBook public immutable book;
  mapping(bytes32 marketHash => Cfg) public cfg;

  event Configured(bytes32 indexed marketHash, address underwriter, address asset);

  error AlreadyConfigured();

  constructor(SolventBook _book) {
    book = _book;
  }

  function configure(bytes32 marketHash, address underwriter, address asset) external {
    if (cfg[marketHash].set) revert AlreadyConfigured();
    cfg[marketHash] = Cfg({underwriter: underwriter, asset: asset, set: true});
    emit Configured(marketHash, underwriter, asset);
  }

  function check(bytes32 marketHash, uint256) external view returns (bool triggered, uint256 payoutBps) {
    Cfg memory c = cfg[marketHash];
    if (!c.set) return (false, 0);
    (uint256 backing, uint256 outstanding,) = book.books(c.underwriter, c.asset);
    if (outstanding == 0 || backing >= outstanding) return (false, 0);
    payoutBps = (outstanding - backing) * BPS / outstanding; // proportional to shortfall
    triggered = true;
  }
}
