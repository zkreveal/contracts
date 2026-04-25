// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";

contract Deploy is Script {
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 1_000;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        address treasuryMultisig = vm.envOr("TREASURY_MULTISIG", address(0));
        uint256 receiptProtocolFeeBpsRaw = vm.envUint("RECEIPT_PROTOCOL_FEE_BPS");

        require(pk != 0, "DEPLOYER_PRIVATE_KEY is zero");
        require(settlementToken != address(0), "SETTLEMENT_TOKEN is zero");
        require(receiptProtocolFeeBpsRaw <= MAX_PROTOCOL_FEE_BPS, "RECEIPT_PROTOCOL_FEE_BPS too high");
        if (receiptProtocolFeeBpsRaw > 0) {
            require(treasuryMultisig != address(0), "TREASURY_MULTISIG is zero");
        }

        // casting is safe because the value is capped to MAX_PROTOCOL_FEE_BPS (1_000)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 receiptProtocolFeeBps = uint16(receiptProtocolFeeBpsRaw);

        console2.log("=== zkReveal ReceiptStore Deployment ===");
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(pk);
        RevealReceiptStore receiptStore =
            new RevealReceiptStore(settlementToken, treasuryMultisig, receiptProtocolFeeBps);
        vm.stopBroadcast();

        console2.log("ChainId:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("SettlementToken:", settlementToken);
        console2.log("TreasuryMultisig:", treasuryMultisig);
        console2.log("ReceiptProtocolFeeBps:", receiptProtocolFeeBps);
        console2.log("ReceiptStore:", address(receiptStore));
    }
}
