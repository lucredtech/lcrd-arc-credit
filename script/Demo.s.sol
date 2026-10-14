// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CreditLine, IERC20} from "../src/CreditLine.sol";

interface IERC20Full is IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// Runs one full lending cycle on a deployed pool, with real USDC:
///   lender deposits -> underwriter opens a line backed by a score report hash
///   -> borrower draws -> borrower repays part, leaving a live loan.
///
///   POOL=0x... forge script script/Demo.s.sol --rpc-url arc --broadcast
contract Demo is Script {
    IERC20Full constant USDC = IERC20Full(0x3600000000000000000000000000000000000000);
    uint256 constant ONE = 1e6;

    function run() external {
        CreditLine pool = CreditLine(vm.envAddress("POOL"));
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 borrowerKey = vm.envUint("BORROWER_PRIVATE_KEY");
        address borrower = vm.addr(borrowerKey);

        // The line is justified by an off-chain score report; only its hash goes on-chain.
        bytes32 scoreRef = keccak256(bytes(vm.readFile("docs/demo-score-report.json")));
        console2.log("scoreRef:");
        console2.logBytes32(scoreRef);

        vm.startBroadcast(deployerKey);
        USDC.approve(address(pool), 5 * ONE);
        pool.deposit(5 * ONE); // lender
        pool.setLine(borrower, uint128(3 * ONE), 1_200, 2, scoreRef); // underwriter: 3 USDC at 12%, tier 2
        USDC.transfer(borrower, ONE / 2); // gas money for the borrower wallet
        vm.stopBroadcast();

        vm.startBroadcast(borrowerKey);
        pool.borrow(2 * ONE);
        USDC.approve(address(pool), ONE);
        pool.repay(ONE);
        vm.stopBroadcast();

        (uint256 p, uint256 i) = pool.owed(borrower);
        console2.log("borrower:", borrower);
        console2.log("principal outstanding:", p);
        console2.log("interest outstanding:", i);
    }
}
