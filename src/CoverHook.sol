// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

/// @title CoverHook
/// @notice The Uniswap v4 trigger/measurement layer for Airbag: LP impermanent-loss cover + depeg alerts.
///         - beforeAddLiquidity snapshots the LP's entry tick (the real LP, resolved via IMsgSender).
///         - beforeRemoveLiquidity records the exit tick, so realized IL is measurable on-chain.
///         - beforeSwap remembers each block's opening tick (flash-manipulation guard) and flags a
///           depeg when the pool price crosses a configured band.
///         `ILTrigger` (core unit) reads this hook to pay IL cover through CoverApp.claim().
///         Deployed only on Arbitrum (v4 is not on Robinhood Chain).
/// @dev Must be deployed to a CREATE2 address whose low bits match getHookPermissions() (HookMiner).
contract CoverHook is BaseHook {
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;

  struct Entry {
    int24 entryTick;
    int24 exitTick;
    uint64 enteredAt;
    uint64 exitedAt;
    bool active;
  }

  /// @notice Per-pool depeg band, in ticks, relative to a reference tick (0 = disabled).
  struct DepegBand {
    int24 refTick;
    int24 lowerTick; // depeg flagged when current tick < lowerTick
    bool set;
  }

  uint256 internal constant WAD = 1e18;
  int256 internal constant MAX_IL_TICKS = 400_000; // beyond this the price ratio is ~e^40: IL ~ 100%

  mapping(PoolId => mapping(address => Entry)) public entryOf;
  mapping(PoolId => DepegBand) public depegBand;
  mapping(PoolId => uint256) public swapCount;
  mapping(PoolId => uint256) public lastSwapBlock;
  mapping(PoolId => int24) internal blockOpenTick;

  event EntrySnapshot(PoolId indexed pool, address indexed lp, int24 tick);
  event ILMeasured(PoolId indexed pool, address indexed lp, int24 entryTick, int24 exitTick, uint256 ilBps);
  event DepegFlagged(PoolId indexed pool, int24 tick, int24 lowerTick);
  event DepegBandSet(PoolId indexed pool, int24 refTick, int24 lowerTick);

  constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: false,
      afterInitialize: false,
      beforeAddLiquidity: true, // snapshot entry for IL
      afterAddLiquidity: false,
      beforeRemoveLiquidity: true, // record exit for realized IL
      afterRemoveLiquidity: false,
      beforeSwap: true, // block-open tick + depeg trigger
      afterSwap: true, // activity counter
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: false,
      afterSwapReturnDelta: false,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  /// @notice Configure a per-pool depeg band (ticks). `lowerTick` is the depeg threshold.
  function setDepegBand(PoolKey calldata key, int24 refTick, int24 lowerTick) external {
    PoolId id = key.toId();
    depegBand[id] = DepegBand({refTick: refTick, lowerTick: lowerTick, set: true});
    emit DepegBandSet(id, refTick, lowerTick);
  }

  // ── v4 callbacks ───────────────────────────────────────────────────────────

  function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
    internal
    override
    returns (bytes4)
  {
    PoolId id = key.toId();
    address lp = _lpOf(sender);
    Entry storage e = entryOf[id][lp];
    if (!e.active) {
      // a fresh position; top-ups of a live position keep the original entry
      int24 tick = settledTick(id);
      entryOf[id][lp] =
        Entry({entryTick: tick, exitTick: 0, enteredAt: uint64(block.timestamp), exitedAt: 0, active: true});
      emit EntrySnapshot(id, lp, tick);
    }
    return BaseHook.beforeAddLiquidity.selector;
  }

  function _beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
    internal
    override
    returns (bytes4)
  {
    PoolId id = key.toId();
    address lp = _lpOf(sender);
    Entry storage e = entryOf[id][lp];
    if (e.active) {
      int24 tick = settledTick(id);
      e.exitTick = tick;
      e.exitedAt = uint64(block.timestamp);
      e.active = false;
      emit ILMeasured(id, lp, e.entryTick, tick, ilBps(e.entryTick, tick));
    }
    return BaseHook.beforeRemoveLiquidity.selector;
  }

  function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
    internal
    override
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    PoolId id = key.toId();
    (, int24 tick,,) = poolManager.getSlot0(id);
    if (lastSwapBlock[id] != block.number) {
      // first swap this block: the pre-swap tick is where the pool closed last block
      lastSwapBlock[id] = block.number;
      blockOpenTick[id] = tick;
    }
    DepegBand storage band = depegBand[id];
    if (band.set && tick < band.lowerTick) emit DepegFlagged(id, tick, band.lowerTick);
    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
  }

  function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
    internal
    override
    returns (bytes4, int128)
  {
    swapCount[key.toId()]++;
    return (BaseHook.afterSwap.selector, 0);
  }

  // ── Views ──────────────────────────────────────────────────────────────────

  /// @notice The pool tick as of the start of this block. Swaps inside the current block (e.g. a
  ///         flash-loan price push) cannot move it, so IL read through it can't be pumped atomically.
  function settledTick(PoolId id) public view returns (int24) {
    if (lastSwapBlock[id] == block.number) return blockOpenTick[id];
    (, int24 tick,,) = poolManager.getSlot0(id);
    return tick;
  }

  /// @notice Full-range impermanent loss (bps) for a price move from `fromTick` to `toTick`:
  ///         IL = 1 - 2*sqrt(r)/(1+r), r = P_to/P_from. Concentrated positions lose more; this is
  ///         the parametric index the cover pays on.
  function ilBps(int24 fromTick, int24 toTick) public pure returns (uint256) {
    int256 d = int256(toTick) - int256(fromTick);
    if (d == 0) return 0;
    if (d > MAX_IL_TICKS || d < -MAX_IL_TICKS) return 10_000;
    uint256 s = FullMath.mulDiv(TickMath.getSqrtPriceAtTick(toTick), WAD, TickMath.getSqrtPriceAtTick(fromTick)); // sqrt(r)
    uint256 r = FullMath.mulDiv(s, s, WAD);
    uint256 il = WAD - FullMath.mulDiv(2 * s, WAD, WAD + r);
    return il / 1e14;
  }

  /// @notice IL (bps) of an LP's position since entry: realized at exit, else vs the settled tick.
  function currentIlBps(PoolKey calldata key, address lp) external view returns (uint256) {
    PoolId id = key.toId();
    Entry storage e = entryOf[id][lp];
    if (e.enteredAt == 0) return 0;
    return ilBps(e.entryTick, e.active ? settledTick(id) : e.exitTick);
  }

  /// @dev The real LP behind a router: v4 periphery routers (PositionManager, …) expose the
  ///      original caller via IMsgSender; anything else is treated as the LP itself.
  function _lpOf(address sender) internal view returns (address) {
    (bool ok, bytes memory ret) = sender.staticcall(abi.encodeWithSelector(IMsgSender.msgSender.selector));
    if (ok && ret.length == 32) {
      address a = abi.decode(ret, (address));
      if (a != address(0)) return a;
    }
    return sender;
  }
}
