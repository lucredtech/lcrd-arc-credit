// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CreditLine, IERC20} from "../src/CreditLine.sol";

/// Deploys the pool on Arc against native USDC (ERC-20 interface, 6 decimals).
/// The deployer is owner and underwriter to start; hand underwriting to a
/// dedicated key with setUnderwriter.
///
///   forge script script/Deploy.s.sol --rpc-url arc --broadcast
contract Deploy is Script {
    IERC20 constant ARC_USDC = IERC20(0x3600000000000000000000000000000000000000);

    function run() external returns (CreditLine pool) {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        vm.startBroadcast(key);
        pool = new CreditLine(ARC_USDC, deployer);
        vm.stopBroadcast();
        console2.log("CreditLine:", address(pool));
        console2.log("owner/underwriter:", deployer);
    }
}
