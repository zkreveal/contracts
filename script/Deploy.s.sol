// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ZkRevealStore} from "../src/ZkRevealStore.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(pk);
        ZkRevealStore store = new ZkRevealStore();
        vm.stopBroadcast();

        console2.log("ZkRevealStore:", address(store));
    }
}
