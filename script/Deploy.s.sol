// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RakeEngine} from "../src/RakeEngine.sol";
import {RevealDeliveryStore} from "../src/RevealDeliveryStore.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(pk);
        RakeEngine rakeEngine = new RakeEngine(deployer, deployer, 0);
        RevealDeliveryStore store = new RevealDeliveryStore(address(rakeEngine));
        vm.stopBroadcast();

        console2.log("RakeEngine:", address(rakeEngine));
        console2.log("RevealDeliveryStore:", address(store));
    }
}
