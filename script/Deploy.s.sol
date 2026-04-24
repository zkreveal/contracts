// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RakeEngine} from "../src/RakeEngine.sol";
import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";
import {RevealDeliveryStore} from "../src/RevealDeliveryStore.sol";

contract Deploy is Script {
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 1_000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        address treasuryMultisig = vm.envAddress("TREASURY_MULTISIG");
        address adminMultisig = vm.envAddress("ADMIN_MULTISIG");
        uint256 receiptDefaultFeeBpsRaw = vm.envUint("RECEIPT_DEFAULT_FEE_BPS");
        uint256 deliveryDefaultFeeBpsRaw = vm.envUint("DELIVERY_DEFAULT_FEE_BPS");

        require(pk != 0, "DEPLOYER_PRIVATE_KEY is zero");
        require(settlementToken != address(0), "SETTLEMENT_TOKEN is zero");
        require(treasuryMultisig != address(0), "TREASURY_MULTISIG is zero");
        require(adminMultisig != address(0), "ADMIN_MULTISIG is zero");
        require(receiptDefaultFeeBpsRaw <= MAX_PROTOCOL_FEE_BPS, "RECEIPT_DEFAULT_FEE_BPS too high");
        require(deliveryDefaultFeeBpsRaw <= MAX_PROTOCOL_FEE_BPS, "DELIVERY_DEFAULT_FEE_BPS too high");

        // casting is safe because both values are capped to MAX_PROTOCOL_FEE_BPS (1_000)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 receiptDefaultFeeBps = uint16(receiptDefaultFeeBpsRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 deliveryDefaultFeeBps = uint16(deliveryDefaultFeeBpsRaw);

        console2.log("=== zkReveal v1 Deployment ===");
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(pk);
        RakeEngine receiptRakeEngine = new RakeEngine(adminMultisig, treasuryMultisig, receiptDefaultFeeBps);
        RevealReceiptStore receiptStore = new RevealReceiptStore(address(receiptRakeEngine), settlementToken);

        RakeEngine deliveryRakeEngine = new RakeEngine(adminMultisig, treasuryMultisig, deliveryDefaultFeeBps);
        RevealDeliveryStore deliveryStore = new RevealDeliveryStore(address(deliveryRakeEngine), settlementToken);
        vm.stopBroadcast();

        console2.log("ChainId:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("SettlementToken:", settlementToken);
        console2.log("TreasuryMultisig:", treasuryMultisig);
        console2.log("AdminMultisig:", adminMultisig);
        console2.log("ReceiptDefaultFeeBps:", receiptDefaultFeeBps);
        console2.log("DeliveryDefaultFeeBps:", deliveryDefaultFeeBps);
        console2.log("ReceiptRakeEngine:", address(receiptRakeEngine));
        console2.log("ReceiptStore:", address(receiptStore));
        console2.log("DeliveryRakeEngine:", address(deliveryRakeEngine));
        console2.log("DeliveryStore:", address(deliveryStore));
    }
}
