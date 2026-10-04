// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";

import {CoverApp} from "../src/CoverApp.sol";
import {CoverNote} from "../src/CoverNote.sol";
import {CoverRouter} from "../src/CoverRouter.sol";
import {SolventBook} from "../src/SolventBook.sol";
import {ILTrigger} from "../src/triggers/ILTrigger.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice Deploys the Airbag core stack (CoverApp + CoverNote + SolventBook + CoverRouter) on an
///         Arbitrum chain (Arbitrum Sepolia / Arbitrum One / Robinhood Chain — a custom Orbit chain).
///         Reuses the canonical 1inch Aqua registry. On a testnet without mainnet USDG it also
///         deploys a mock USDG + oracle so the full flow is demoable.
///
/// Env:
///   AQUA        canonical AquaRouter address (verify the current one before use)
///   USDG        USDG token address (0 => deploy a mock)
///   ORACLE      price oracle address (0 => deploy a mock at $1.00)
///   USE_BOOK    wire the attestor-fed SolventBook aggregate floor (default false: until an
///               attestor posts a book, headroom() is 0 and every buy would revert)
contract Deploy is Script {
  function run() external {
    address aqua = vm.envAddress("AQUA");
    address usdg = vm.envOr("USDG", address(0));
    address oracle = vm.envOr("ORACLE", address(0));
    address deployer = msg.sender;

    vm.startBroadcast();

    if (usdg == address(0)) {
      usdg = address(new MockERC20("Global Dollar", "USDG"));
      console.log("Mock USDG:", usdg);
    }
    if (oracle == address(0)) {
      oracle = address(new MockOracle(8, 1e8));
      console.log("Mock Oracle ($1.00):", oracle);
    }

    CoverApp cover = new CoverApp(IAqua(aqua), deployer);
    CoverNote note = new CoverNote(address(cover));
    SolventBook book = new SolventBook(deployer);
    CoverRouter router = new CoverRouter(cover);
    cover.initialize(note, vm.envOr("USE_BOOK", false) ? book : SolventBook(address(0)));
    ILTrigger ilTrigger = new ILTrigger(cover); // LP IL cover; reads the v4 CoverHook (DeployHook.s.sol)

    vm.stopBroadcast();

    console.log("=== Airbag core deployed ===");
    console.log("Aqua:       ", aqua);
    console.log("CoverApp:   ", address(cover));
    console.log("CoverNote:  ", address(note));
    console.log("SolventBook:", address(book));
    console.log("CoverRouter:", address(router));
    console.log("ILTrigger:  ", address(ilTrigger));
    console.log("USDG:       ", usdg);
    console.log("Oracle:     ", oracle);
  }
}
