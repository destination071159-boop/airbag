// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

import {CoverHook} from "../src/CoverHook.sol";

contract CoverHookTest is Test {
  PoolManager manager;
  CoverHook hook;
  PoolModifyLiquidityTest lp;
  PoolSwapTest swapper;
  MockERC20 token0;
  MockERC20 token1;
  PoolKey key;

  uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

  function setUp() public {
    manager = new PoolManager(address(this));
    lp = new PoolModifyLiquidityTest(manager);
    swapper = new PoolSwapTest(manager);

    // deploy the hook to an address whose low bits match its permissions
    uint160 flags = uint160(
      Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG
    );
    address hookAddr = address(flags);
    deployCodeTo("CoverHook.sol:CoverHook", abi.encode(manager), hookAddr);
    hook = CoverHook(hookAddr);

    MockERC20 a = new MockERC20("A", "A");
    MockERC20 b = new MockERC20("B", "B");
    (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
    token0.mint(address(this), 1e24);
    token1.mint(address(this), 1e24);
    token0.approve(address(lp), type(uint256).max);
    token1.approve(address(lp), type(uint256).max);
    token0.approve(address(swapper), type(uint256).max);
    token1.approve(address(swapper), type(uint256).max);

    key = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 3000,
      tickSpacing: 60,
      hooks: IHooks(hookAddr)
    });
    manager.initialize(key, SQRT_PRICE_1_1);
  }

  function test_hook_permissions_valid() public view {
    Hooks.Permissions memory p = hook.getHookPermissions();
    assertTrue(p.beforeAddLiquidity && p.beforeRemoveLiquidity && p.beforeSwap && p.afterSwap);
  }

  function test_add_liquidity_snapshots_entry() public {
    lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e21, salt: 0}), "");
    // the LP router is the `sender` seen by the hook
    (,, uint64 ts,, bool active) = hook.entryOf(key.toId(), address(lp));
    assertTrue(active, "entry snapshotted");
    assertGt(ts, 0);
  }

  function test_swap_increments_counter() public {
    lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e21, salt: 0}), "");
    swapper.swap(
      key,
      SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1e18}),
      PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
      ""
    );
    assertEq(hook.swapCount(key.toId()), 1, "swap counted");
  }

  function test_remove_liquidity_measures_il() public {
    lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e21, salt: 0}), "");
    lp.modifyLiquidity(
      key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -1e21, salt: 0}), ""
    );
    (,,, uint64 exitedAt, bool active) = hook.entryOf(key.toId(), address(lp));
    assertFalse(active, "position closed");
    assertGt(exitedAt, 0, "exit recorded for realized IL");
  }
}
