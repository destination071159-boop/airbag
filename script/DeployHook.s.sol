// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CoverHook} from "../src/CoverHook.sol";

/// @notice Mines a CREATE2 salt so the CoverHook lands at an address whose low bits match its
///         permissions, then deploys it. Arbitrum only (v4 is not on Robinhood Chain).
///
/// Env:
///   POOL_MANAGER  the Uniswap v4 PoolManager (Arbitrum One / Sepolia: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32)
contract DeployHook is Script {
  // CREATE2_FACTORY is inherited from forge-std's Script (0x4e59b44847b379578588920cA78FbF26c0B4956C)

  function run() external {
    address poolManager = vm.envAddress("POOL_MANAGER");

    uint160 flags = uint160(
      Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG
    );
    bytes memory args = abi.encode(IPoolManager(poolManager));
    (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, flags, type(CoverHook).creationCode, args);

    vm.startBroadcast();
    CoverHook hook = new CoverHook{salt: salt}(IPoolManager(poolManager));
    vm.stopBroadcast();

    require(address(hook) == hookAddr, "hook address mismatch");
    console.log("CoverHook:", address(hook));
    console.log("PoolManager:", poolManager);
  }
}
