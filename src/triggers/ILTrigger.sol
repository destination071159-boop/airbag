// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITrigger} from "../interfaces/ITrigger.sol";
import {CoverApp} from "../CoverApp.sol";

/// @notice The slice of CoverHook (v4 unit, separate compiler) this trigger reads. PoolId is bytes32.
interface ICoverHookIL {
  function entryOf(bytes32 poolId, address lp)
    external
    view
    returns (int24 entryTick, int24 exitTick, uint64 enteredAt, uint64 exitedAt, bool active);
  function settledTick(bytes32 poolId) external view returns (int24);
  function ilBps(int24 fromTick, int24 toTick) external pure returns (uint256);
}

/// @title ILTrigger
/// @notice Parametric LP impermanent-loss cover on a Uniswap v4 pool, paid through CoverApp.claim().
///         1. The underwriter points a CoverApp market at this trigger and configures the pool,
///            deductible and cap.
///         2. An LP buys a policy, then `bind`s it to their live position in that pool. The baseline
///            is the pool's settled tick at bind time — cover bought after a move pays nothing for it.
///         3. On claim, IL since the baseline is read from CoverHook (realized at exit, else vs the
///            block-open tick) and paid as (IL - deductible) / (cap - deductible) of the notional.
contract ILTrigger is ITrigger {
  struct Config {
    address hook;
    bytes32 poolId;
    uint16 deductibleBps; // IL below this pays nothing
    uint16 capBps; // IL at/above this pays the full notional
    bool set;
  }

  struct Binding {
    address lp;
    int24 baseTick;
    uint64 enteredAt; // identifies the LP position the policy covers
    bool set;
  }

  uint256 internal constant BPS = 10_000;

  CoverApp public immutable coverApp;
  mapping(bytes32 marketHash => Config) public configs;
  mapping(uint256 policyId => Binding) public bindings;

  event Configured(bytes32 indexed marketHash, address hook, bytes32 poolId, uint16 deductibleBps, uint16 capBps);
  event Bound(uint256 indexed policyId, address indexed lp, bytes32 indexed poolId, int24 baseTick);

  error AlreadyConfigured();
  error NotUnderwriter();
  error BadParams();
  error NotConfigured();
  error AlreadyBound();
  error NotNoteHolder();
  error PolicyInactive();
  error NoLivePosition();

  constructor(CoverApp _coverApp) {
    coverApp = _coverApp;
  }

  /// @notice Underwriter-only, once per market: which pool this market covers and the payout band.
  function configure(bytes32 marketHash, address hook, bytes32 poolId, uint16 deductibleBps, uint16 capBps) external {
    (address underwriter,,,,,,,,,, address trigger,) = coverApp.markets(marketHash);
    if (msg.sender != underwriter) revert NotUnderwriter();
    if (trigger != address(this) || capBps <= deductibleBps || capBps > BPS) revert BadParams();
    if (configs[marketHash].set) revert AlreadyConfigured();
    configs[marketHash] =
      Config({hook: hook, poolId: poolId, deductibleBps: deductibleBps, capBps: capBps, set: true});
    emit Configured(marketHash, hook, poolId, deductibleBps, capBps);
  }

  /// @notice Bind a policy to the caller's live LP position. Callable once, by the note holder.
  function bind(uint256 policyId) external {
    (bytes32 marketHash,, uint64 expiry, bool claimed,,,,) = coverApp.policies(policyId);
    Config memory c = configs[marketHash];
    if (!c.set) revert NotConfigured();
    if (bindings[policyId].set) revert AlreadyBound();
    if (claimed || block.timestamp > expiry) revert PolicyInactive();
    if (coverApp.coverNote().balanceOf(msg.sender, policyId) == 0) revert NotNoteHolder();
    (,, uint64 enteredAt,, bool active) = ICoverHookIL(c.hook).entryOf(c.poolId, msg.sender);
    if (!active) revert NoLivePosition();

    int24 baseTick = ICoverHookIL(c.hook).settledTick(c.poolId);
    bindings[policyId] = Binding({lp: msg.sender, baseTick: baseTick, enteredAt: enteredAt, set: true});
    emit Bound(policyId, msg.sender, c.poolId, baseTick);
  }

  /// @notice IL (bps) since the policy's baseline and the payout fraction it maps to.
  function preview(uint256 policyId) public view returns (uint256 ilBps, uint256 payoutBps) {
    Binding memory b = bindings[policyId];
    if (!b.set) return (0, 0);
    (bytes32 marketHash,,,,,,,) = coverApp.policies(policyId);
    Config memory c = configs[marketHash];
    ICoverHookIL hook = ICoverHookIL(c.hook);
    (, int24 exitTick, uint64 enteredAt,, bool active) = hook.entryOf(c.poolId, b.lp);
    if (enteredAt != b.enteredAt) return (0, 0); // the covered position was closed and replaced
    ilBps = hook.ilBps(b.baseTick, active ? hook.settledTick(c.poolId) : exitTick);
    if (ilBps <= c.deductibleBps) return (ilBps, 0);
    payoutBps = (ilBps - c.deductibleBps) * BPS / (c.capBps - c.deductibleBps);
    if (payoutBps > BPS) payoutBps = BPS;
  }

  function check(bytes32, uint256 policyId) external view returns (bool triggered, uint256 payoutBps) {
    (, payoutBps) = preview(policyId);
    triggered = payoutBps > 0;
  }
}
