// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {CoverHook} from "../src/CoverHook.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {YieldReserve} from "../src/YieldReserve.sol";
import {IReserveHook} from "../src/interfaces/IReserveHook.sol";
import {ILTrigger} from "../src/triggers/ILTrigger.sol";
import {PriceGapTrigger} from "../src/triggers/PriceGapTrigger.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {DripVault} from "../src/mocks/DripVault.sol";
import {DemoLiquidityRouter} from "../src/mocks/DemoLiquidityRouter.sol";

/// @notice Full demo stack for the frontend — three live cover products on one CoverApp:
///           1. USDG depeg cover   — reserve sits in a 4.5% APR savings vault via YieldReserve
///           2. LP IL cover        — a real Uniswap v4 wstETH/WETH pool with CoverHook + ILTrigger
///           3. Stock gap cover    — tokenized TSLAx, proportional payout via PriceGapTrigger
///         Writes every address to frontend/src/lib/deployment.json.
///
/// Env: AQUA (0 => fresh Aqua), POOL_MANAGER (0 => fresh v4 PoolManager)
contract DeployDemo is Script {
  using PoolIdLibrary for PoolKey;

  struct Core {
    address aqua;
    MockERC20 usdg;
    MockOracle usdOracle;
    CoverApp cover;
    CoverNote note;
    ILTrigger ilTrigger;
    PriceGapTrigger gapTrigger;
  }

  address deployer;
  string json = "deployment";
  uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

  function run() external {
    deployer = msg.sender;
    vm.startBroadcast();
    Core memory c = _core();
    bytes32 depeg = _depegMarket(c);
    bytes32 gap = _gapMarket(c);
    bytes32 il = _ilMarket(c);
    vm.stopBroadcast();
    _seedBook(c, depeg, gap);

    vm.serializeUint(json, "chainId", block.chainid);
    vm.serializeUint(json, "startBlock", 0);
    vm.serializeAddress(json, "aqua", c.aqua);
    vm.serializeAddress(json, "usdg", address(c.usdg));
    vm.serializeAddress(json, "oracle", address(c.usdOracle));
    vm.serializeAddress(json, "coverApp", address(c.cover));
    vm.serializeAddress(json, "coverNote", address(c.note));
    vm.serializeAddress(json, "ilTrigger", address(c.ilTrigger));
    vm.serializeAddress(json, "gapTrigger", address(c.gapTrigger));
    vm.serializeAddress(json, "underwriter", deployer);
    vm.serializeAddress(json, "coverRouter", address(0)); // filled in by AddMarketplace.s.sol
    vm.serializeBytes32(json, "market", depeg);
    vm.serializeBytes32(json, "gapMarket", gap);
    string memory out = vm.serializeBytes32(json, "ilMarket", il);
    vm.writeJson(out, string.concat("./frontend/src/lib/deployment.", vm.toString(block.chainid), ".json"));
    console.log("=== Airbag demo deployed: depeg / IL / gap markets live ===");
  }

  /// Seed a live book so the demo isn't empty: three other wallets already hold cover. Locally these
  /// are public anvil dev keys; on a testnet they are throwaway keys derived from the deployer key
  /// and funded with a little gas.
  function _seedBook(Core memory c, bytes32 depeg, bytes32 gap) internal {
    uint256[3] memory keys;
    if (block.chainid == 31_337) {
      keys = [
        uint256(0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6),
        uint256(0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a),
        uint256(0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba)
      ];
    } else {
      string memory pk = vm.envString("PRIVATE_KEY");
      uint256 root = vm.parseUint(bytes(pk).length == 64 ? string.concat("0x", pk) : pk); // with or without 0x
      vm.startBroadcast(root);
      for (uint256 i; i < 3; i++) {
        keys[i] = uint256(keccak256(abi.encode(root, "airbag-seed", i))) % SECP256K1_N;
        payable(vm.addr(keys[i])).transfer(0.0003 ether);
      }
      vm.stopBroadcast();
    }
    bytes32[4] memory mkts = [depeg, depeg, gap, gap];
    uint256[4] memory notional = [uint256(120_000e18), 80_000e18, 60_000e18, 40_000e18];
    uint64[4] memory term = [uint64(30 days), 14 days, 30 days, 7 days];
    for (uint256 i; i < 4; i++) {
      vm.startBroadcast(keys[i % 3]);
      address who = vm.addr(keys[i % 3]);
      uint256 premium = c.cover.quotePremium(mkts[i], notional[i]);
      c.usdg.mint(who, premium);
      c.usdg.approve(address(c.cover), premium);
      c.cover.buyPolicy(mkts[i], notional[i], term[i]);
      vm.stopBroadcast();
    }
  }

  function _core() internal returns (Core memory c) {
    c.aqua = vm.envOr("AQUA", address(0));
    if (c.aqua == address(0)) c.aqua = address(new Aqua());
    c.usdg = new MockERC20("Global Dollar", "USDG");
    c.usdOracle = new MockOracle(8, 1e8);
    c.cover = new CoverApp(IAqua(c.aqua), deployer);
    c.note = new CoverNote(address(c.cover));
    c.cover.initialize(c.note, SolventBook(address(0)));
    c.ilTrigger = new ILTrigger(c.cover);
    c.gapTrigger = new PriceGapTrigger();
    c.usdg.mint(deployer, 2_000_000e18);
    c.usdg.approve(c.aqua, type(uint256).max);
  }

  function _market(Core memory c, address maker, address oracle, uint256 peg, uint16 band, address trigger, uint256 start, uint256 end, uint256 k, uint256 salt)
    internal
    pure
    returns (CoverApp.Market memory)
  {
    return CoverApp.Market({
      underwriter: maker,
      asset: address(c.usdg),
      oracle: oracle,
      pegPrice: peg,
      depegBps: band,
      maxUtilBps: 8000,
      oracleTimeout: 1 days,
      startRateWad: start,
      endRateWad: end,
      convexityWad: k,
      trigger: trigger,
      salt: bytes32(salt)
    });
  }

  function _one(address token, uint256 amount) internal pure returns (address[] memory t, uint256[] memory a) {
    t = new address[](1);
    t[0] = token;
    a = new uint256[](1);
    a[0] = amount;
  }

  /// 1. USDG depeg — the reserve earns 4.5% in a savings vault while it backs cover.
  function _depegMarket(Core memory c) internal returns (bytes32 hash) {
    DripVault vault = new DripVault(IERC20(address(c.usdg)), 450);
    YieldReserve reserve = new YieldReserve(deployer, address(c.cover), IERC20(address(c.usdg)), IERC4626(address(vault)));
    uint256 amount = 1_000_000e18;
    c.usdg.approve(address(reserve), amount);
    reserve.deposit(amount);
    reserve.approveAqua(c.aqua);

    CoverApp.Market memory m =
      _market(c, address(reserve), address(c.usdOracle), 1e8, 300, address(0), 0.01e18, 0.1e18, 1e18, 1);
    (address[] memory t, uint256[] memory a) = _one(address(c.usdg), amount);
    hash = abi.decode(reserve.execute(c.aqua, abi.encodeCall(IAqua.ship, (address(c.cover), abi.encode(m), t, a))), (bytes32));
    reserve.execute(address(c.cover), abi.encodeCall(CoverApp.registerMarket, (m)));
    reserve.execute(address(c.cover), abi.encodeCall(CoverApp.setReserveHook, (IReserveHook(address(reserve)))));

    vm.serializeAddress(json, "vault", address(vault));
    vm.serializeAddress(json, "yieldReserve", address(reserve));
  }

  /// 3. Tokenized-stock gap cover — pays by how far TSLAx falls below $250.
  function _gapMarket(Core memory c) internal returns (bytes32 hash) {
    MockOracle stock = new MockOracle(8, 250e8);
    CoverApp.Market memory m =
      _market(c, deployer, address(stock), 250e8, 0, address(c.gapTrigger), 0.02e18, 0.15e18, 1.5e18, 2);
    (address[] memory t, uint256[] memory a) = _one(address(c.usdg), 300_000e18);
    hash = IAqua(c.aqua).ship(address(c.cover), abi.encode(m), t, a);
    c.cover.registerMarket(m);
    c.gapTrigger.configure(hash, address(stock), 250e8, 1 days);
    vm.serializeAddress(json, "stockOracle", address(stock));
  }

  /// 2. LP impermanent-loss cover on a real v4 pool.
  function _ilMarket(Core memory c) internal returns (bytes32 hash) {
    IPoolManager manager = IPoolManager(vm.envOr("POOL_MANAGER", address(0)));
    if (address(manager) == address(0)) {
      manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(deployer)));
    }
    uint160 flags = uint160(
      Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG
    );
    (, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, flags, type(CoverHook).creationCode, abi.encode(manager));
    CoverHook hook = new CoverHook{salt: salt}(manager);

    MockERC20 a = new MockERC20("Wrapped stETH", "wstETH");
    MockERC20 b = new MockERC20("Wrapped Ether", "WETH");
    (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
    PoolKey memory key = PoolKey({
      currency0: Currency.wrap(address(t0)),
      currency1: Currency.wrap(address(t1)),
      fee: 3000,
      tickSpacing: 60,
      hooks: IHooks(address(hook))
    });
    manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

    DemoLiquidityRouter router = new DemoLiquidityRouter(manager);
    PoolSwapTest swapper = new PoolSwapTest(manager);
    // deployer seeds deep liquidity so demo swaps have something to trade against
    t0.mint(deployer, 1e25);
    t1.mint(deployer, 1e25);
    t0.approve(address(router), type(uint256).max);
    t1.approve(address(router), type(uint256).max);
    router.modifyAs(key, -12_000, 12_000, 1e22);

    CoverApp.Market memory m =
      _market(c, deployer, address(0), 0, 0, address(c.ilTrigger), 0.02e18, 0.12e18, 2e18, 3);
    (address[] memory t, uint256[] memory amt) = _one(address(c.usdg), 500_000e18);
    hash = IAqua(c.aqua).ship(address(c.cover), abi.encode(m), t, amt);
    c.cover.registerMarket(m);
    c.ilTrigger.configure(hash, address(hook), PoolId.unwrap(key.toId()), 50, 500);

    vm.serializeAddress(json, "poolManager", address(manager));
    vm.serializeAddress(json, "hook", address(hook));
    vm.serializeAddress(json, "lpRouter", address(router));
    vm.serializeAddress(json, "swapper", address(swapper));
    vm.serializeAddress(json, "token0", address(t0));
    vm.serializeAddress(json, "token1", address(t1));
    vm.serializeString(json, "token0Symbol", t0.symbol());
    vm.serializeString(json, "token1Symbol", t1.symbol());
    vm.serializeBytes32(json, "poolId", PoolId.unwrap(key.toId()));
  }
}
