// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverRouter} from "../src/CoverRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Turns USDG depeg cover into a marketplace: deploys the CoverRouter and has two more
///         independent underwriters open competing depeg markets with different risk curves.
///         Buyers are routed across all of them (cheapest marginal premium first) in one tx.
///         Run after DeployDemo; patches `coverRouter` into frontend/src/lib/deployment.<chainid>.json.
contract AddMarketplace is Script {
  uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

  struct Curve {
    uint256 start;
    uint256 end;
    uint256 k;
    uint256 reserve;
  }

  function run() external {
    string memory path = string.concat("./frontend/src/lib/deployment.", vm.toString(block.chainid), ".json");
    string memory dep = vm.readFile(path);
    CoverApp cover = CoverApp(vm.parseJsonAddress(dep, ".coverApp"));
    IAqua aqua = IAqua(vm.parseJsonAddress(dep, ".aqua"));
    MockERC20 usdg = MockERC20(vm.parseJsonAddress(dep, ".usdg"));
    address oracle = vm.parseJsonAddress(dep, ".oracle");

    uint256[2] memory keys = _underwriterKeys();
    Curve[2] memory curves = [
      Curve({start: 0.006e18, end: 0.14e18, k: 2.5e18, reserve: 400_000e18}), // cheap until busy, then steep
      Curve({start: 0.015e18, end: 0.06e18, k: 1e18, reserve: 600_000e18}) // steady, flat-ish
    ];

    vm.startBroadcast();
    CoverRouter router = new CoverRouter(cover);
    vm.stopBroadcast();

    for (uint256 i; i < 2; i++) {
      address uw = vm.addr(keys[i]);
      CoverApp.Market memory m = CoverApp.Market({
        underwriter: uw,
        asset: address(usdg),
        oracle: oracle,
        pegPrice: 1e8,
        depegBps: 300,
        maxUtilBps: 8000,
        oracleTimeout: 1 days,
        startRateWad: curves[i].start,
        endRateWad: curves[i].end,
        convexityWad: curves[i].k,
        trigger: address(0),
        salt: bytes32(uint256(100 + i))
      });
      address[] memory t = new address[](1);
      t[0] = address(usdg);
      uint256[] memory a = new uint256[](1);
      a[0] = curves[i].reserve;
      vm.startBroadcast(keys[i]);
      usdg.mint(uw, curves[i].reserve);
      usdg.approve(address(aqua), type(uint256).max);
      aqua.ship(address(cover), abi.encode(m), t, a);
      cover.registerMarket(m);
      vm.stopBroadcast();
      console.log("underwriter", i, uw);
    }

    vm.writeJson(vm.toString(address(router)), path, ".coverRouter");
    console.log("CoverRouter:", address(router));
  }

  /// Local: public anvil dev keys #6/#7. Testnet: throwaway keys derived from the deployer key,
  /// funded with a little gas by the deployer.
  function _underwriterKeys() internal returns (uint256[2] memory keys) {
    if (block.chainid == 31_337) {
      return [
        uint256(0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e),
        uint256(0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356)
      ];
    }
    string memory pk = vm.envString("PRIVATE_KEY");
    uint256 root = vm.parseUint(bytes(pk).length == 64 ? string.concat("0x", pk) : pk);
    vm.startBroadcast(root);
    for (uint256 i; i < 2; i++) {
      keys[i] = uint256(keccak256(abi.encode(root, "airbag-underwriter", i))) % SECP256K1_N;
      payable(vm.addr(keys[i])).transfer(0.0004 ether);
    }
    vm.stopBroadcast();
  }
}
