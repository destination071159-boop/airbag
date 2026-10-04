// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {CoverHook} from "../src/CoverHook.sol";
import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {ILTrigger} from "../src/triggers/ILTrigger.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice A liquidity router that exposes its caller the way v4-periphery's PositionManager does.
contract MsgSenderLiquidityRouter is PoolModifyLiquidityTest, IMsgSender {
  address public msgSender;

  constructor(IPoolManager m) PoolModifyLiquidityTest(m) {}

  function modifyAs(PoolKey memory key, ModifyLiquidityParams memory params) external {
    msgSender = msg.sender;
    modifyLiquidity(key, params, "", false, false); // internal call: tokens settle from the LP
    msgSender = address(0);
  }
}

/// @notice LP impermanent-loss cover end to end: v4 pool + CoverHook measure IL, ILTrigger maps it
///         to a payout, CoverApp pays it atomically from the underwriter's Aqua reserve.
contract ILCoverTest is Test {
  using PoolIdLibrary for PoolKey;

  IPoolManager manager;
  CoverHook hook;
  MsgSenderLiquidityRouter router;
  PoolSwapTest swapper;
  MockERC20 token0;
  MockERC20 token1;
  PoolKey key;

  Aqua aqua;
  CoverApp cover;
  CoverNote note;
  ILTrigger trigger;
  MockERC20 usdg;
  bytes32 market;

  address underwriter = makeAddr("underwriter");
  address alice = makeAddr("alice"); // LP
  address bob = makeAddr("bob"); // LP who buys cover late
  address eve = makeAddr("eve"); // not an LP

  ModifyLiquidityParams range = ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0});

  uint16 constant DEDUCTIBLE = 50; // 0.5% IL
  uint16 constant CAP = 500; // 5% IL pays in full

  function setUp() public {
    // ── Uniswap v4 pool with CoverHook
    manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
    uint160 flags = uint160(
      Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG
    );
    deployCodeTo("CoverHook.sol:CoverHook:0.8.30", abi.encode(manager), address(flags));
    hook = CoverHook(address(flags));
    router = new MsgSenderLiquidityRouter(manager);
    swapper = new PoolSwapTest(manager);

    MockERC20 a = new MockERC20("A", "A");
    MockERC20 b = new MockERC20("B", "B");
    (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
    key = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 3000,
      tickSpacing: 60,
      hooks: IHooks(address(hook))
    });
    manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    _fund(address(this));
    token0.approve(address(swapper), type(uint256).max);
    token1.approve(address(swapper), type(uint256).max);

    // ── Airbag core: an IL-cover market pointed at ILTrigger
    aqua = new Aqua();
    cover = new CoverApp(IAqua(address(aqua)), address(this));
    note = new CoverNote(address(cover));
    cover.initialize(note, SolventBook(address(0)));
    trigger = new ILTrigger(cover);
    usdg = new MockERC20("Global Dollar", "USDG");

    CoverApp.Market memory m = CoverApp.Market({
      underwriter: underwriter,
      asset: address(usdg),
      oracle: address(0),
      pegPrice: 0,
      depegBps: 0,
      maxUtilBps: 8000,
      oracleTimeout: 0,
      startRateWad: 0.02e18,
      endRateWad: 0.12e18,
      convexityWad: 2e18,
      trigger: address(trigger),
      salt: bytes32(uint256(7))
    });
    vm.startPrank(underwriter);
    usdg.mint(underwriter, 1_000_000e18);
    usdg.approve(address(aqua), type(uint256).max);
    address[] memory tokens = new address[](1);
    tokens[0] = address(usdg);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1_000_000e18;
    market = aqua.ship(address(cover), abi.encode(m), tokens, amounts);
    cover.registerMarket(m);
    trigger.configure(market, address(hook), PoolId.unwrap(key.toId()), DEDUCTIBLE, CAP);
    vm.stopPrank();
  }

  // ── helpers ──────────────────────────────────────────────────────────

  function _fund(address who) internal {
    token0.mint(who, 1e24);
    token1.mint(who, 1e24);
    vm.startPrank(who);
    token0.approve(address(router), type(uint256).max);
    token1.approve(address(router), type(uint256).max);
    vm.stopPrank();
  }

  function _provide(address who, uint256 salt) internal {
    _fund(who);
    ModifyLiquidityParams memory p = range;
    p.salt = bytes32(salt);
    vm.prank(who);
    router.modifyAs(key, p);
  }

  function _buyAndBind(address who, uint256 notional) internal returns (uint256 id) {
    vm.startPrank(who);
    uint256 premium = cover.quotePremiumFor(market, notional, 30 days);
    usdg.mint(who, premium);
    usdg.approve(address(cover), premium);
    id = cover.buyPolicy(market, notional, 30 days);
    trigger.bind(id);
    vm.stopPrank();
  }

  /// push the pool price down to `tick` (sells token0)
  function _moveTo(int24 tick) internal {
    swapper.swap(
      key,
      SwapParams({zeroForOne: true, amountSpecified: -1e23, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)}),
      PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
      ""
    );
  }

  // ── tests ────────────────────────────────────────────────────────────

  function test_hook_resolves_real_lp_behind_router() public {
    _provide(alice, 1);
    (,,,, bool aliceActive) = hook.entryOf(key.toId(), alice);
    (,,,, bool routerActive) = hook.entryOf(key.toId(), address(router));
    assertTrue(aliceActive, "entry keyed by the LP");
    assertFalse(routerActive, "not by the router");
  }

  function test_il_math_matches_closed_form() public view {
    assertEq(hook.ilBps(0, 0), 0);
    // r = 1.0001^-4000 ~ 0.6703 -> IL = 1 - 2*sqrt(r)/(1+r) ~ 1.96%
    assertApproxEqAbs(hook.ilBps(0, -4000), 196, 1);
    // symmetric in log-price
    assertEq(hook.ilBps(0, 4000), hook.ilBps(0, -4000));
    // r ~ 0.5488 -> ~4.34%
    assertApproxEqAbs(hook.ilBps(0, -6000), 434, 1);
  }

  function test_il_cover_full_flow_pays_proportionally() public {
    _provide(alice, 1);
    uint256 notional = 100_000e18;
    uint256 id = _buyAndBind(alice, notional);

    // no move yet: nothing to claim
    vm.prank(alice);
    vm.expectRevert(CoverApp.NotTriggered.selector);
    cover.claim(id);

    // the pool price falls ~33% ...
    vm.roll(block.number + 1);
    _moveTo(-4000);

    // ... but within the same block the settled tick hasn't moved: a flash push can't claim
    (uint256 ilSameBlock,) = trigger.preview(id);
    assertEq(ilSameBlock, 0, "same-block move is ignored");

    // next block the move is settled
    vm.roll(block.number + 1);
    (uint256 il, uint256 bps) = trigger.preview(id);
    assertApproxEqAbs(il, 196, 1);
    assertEq(bps, (il - DEDUCTIBLE) * 10_000 / (CAP - DEDUCTIBLE), "payout band");

    uint256 before = usdg.balanceOf(alice);
    vm.prank(alice);
    uint256 payout = cover.claim(id);
    assertEq(payout, notional * bps / 10_000);
    assertEq(usdg.balanceOf(alice) - before, payout, "paid in USDG from the Aqua reserve");
    emit log_named_decimal_uint("IL (%)", il, 2);
    emit log_named_decimal_uint("payout (USDG)", payout, 18);
  }

  function test_realized_il_after_exit() public {
    _provide(alice, 1);
    uint256 id = _buyAndBind(alice, 50_000e18);

    vm.roll(block.number + 1);
    _moveTo(-6000);
    vm.roll(block.number + 1);
    ModifyLiquidityParams memory p = range;
    p.liquidityDelta = -p.liquidityDelta;
    p.salt = bytes32(uint256(1));
    vm.prank(alice);
    router.modifyAs(key, p); // LP exits: IL is locked in at the exit tick

    (uint256 il, uint256 bps) = trigger.preview(id);
    assertApproxEqAbs(il, 434, 1);
    vm.prank(alice);
    assertEq(cover.claim(id), 50_000e18 * bps / 10_000);
  }

  function test_cover_bought_after_the_move_pays_nothing_for_it() public {
    _provide(bob, 2);
    vm.roll(block.number + 1);
    _moveTo(-4000);
    vm.roll(block.number + 1);

    uint256 id = _buyAndBind(bob, 100_000e18); // baseline = post-move tick
    (uint256 il,) = trigger.preview(id);
    assertEq(il, 0, "no retroactive cover");
    vm.prank(bob);
    vm.expectRevert(CoverApp.NotTriggered.selector);
    cover.claim(id);
  }

  function test_only_live_lps_can_bind() public {
    vm.startPrank(eve);
    uint256 premium = cover.quotePremium(market, 10_000e18);
    usdg.mint(eve, premium);
    usdg.approve(address(cover), premium);
    uint256 id = cover.buyPolicy(market, 10_000e18, 30 days);
    vm.expectRevert(ILTrigger.NoLivePosition.selector);
    trigger.bind(id);
    vm.stopPrank();
  }

  function test_only_underwriter_configures() public {
    vm.expectRevert(ILTrigger.NotUnderwriter.selector);
    trigger.configure(market, address(hook), PoolId.unwrap(key.toId()), 0, 100);
  }
}
