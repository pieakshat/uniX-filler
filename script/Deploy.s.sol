// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FillerExecutor, ISwapRouter02} from "../src/fillerExecutor.sol";
import {IReactor} from "UniswapX/src/interfaces/IReactor.sol";

contract Deploy is Script {
    // ─── Arbitrum Mainnet ─────────────────────────────────────────────────────

    /// @dev DutchV3 reactor — current active reactor on Arbitrum
    address constant DUTCH_V3_REACTOR = 0xB274d5F4b833b61B340b654d600A864fB604a87c;

    /// @dev Uniswap SwapRouter02 on Arbitrum
    address constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deploying FillerExecutor...");
        console.log("Deployer:    ", deployer);
        console.log("Reactor:     ", DUTCH_V3_REACTOR);
        console.log("SwapRouter:  ", SWAP_ROUTER_02);

        vm.startBroadcast(deployerKey);

        FillerExecutor executor = new FillerExecutor(
            IReactor(DUTCH_V3_REACTOR),
            ISwapRouter02(SWAP_ROUTER_02)
        );

        vm.stopBroadcast();

        console.log("FillerExecutor deployed at:", address(executor));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Add your Rust backend signer to whitelist:");
        console.log("     executor.setWhitelistedCaller(<SIGNER_ADDRESS>, true)");
        console.log("  2. Fund executor with output tokens if doing inventory-based fills");
        console.log("  3. Set EXECUTOR_CONTRACT=", address(executor), "in filler/.env");
    }
}
