// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";

import {PawnBrokerFactory} from "../src/PawnBrokerFactory.sol";
import {IPawnBroker} from "../src/interfaces/IPawnBroker.sol";

abstract contract DeployConfig {
    address internal constant MANAGEMENT = 0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271;
    address internal constant PERFORMANCE_FEE_RECIPIENT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69;
    address internal constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E;
    address internal constant EMERGENCY_ADMIN = 0xe5e2Baf96198c56380dDD5E992D7d1ADa0e989c0;
}

contract DeployPawnBrokerFactory is Script, DeployConfig {
    function run() external returns (PawnBrokerFactory factory) {
        vm.startBroadcast();
        factory = new PawnBrokerFactory(MANAGEMENT, PERFORMANCE_FEE_RECIPIENT, KEEPER, EMERGENCY_ADMIN);
        vm.stopBroadcast();

        console2.log("PawnBrokerFactory:", address(factory));
        console2.log("Management:", MANAGEMENT);
        console2.log("Performance fee recipient:", PERFORMANCE_FEE_RECIPIENT);
        console2.log("Keeper:", KEEPER);
        console2.log("Emergency admin:", EMERGENCY_ADMIN);
    }
}

