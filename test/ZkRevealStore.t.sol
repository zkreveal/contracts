// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkRevealStore} from "../src/ZkRevealStore.sol";

contract ZkRevealStoreTest is Test {
    ZkRevealStore store;

    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    address buyer2 = address(0xCAFE);
    address attacker = address(0xD00D);

    string title = "Pro Dataset";
    uint256 unitPrice = 0.1 ether;
    uint64 refundWindow = 1 hours;
    bytes buyerPubKey = hex"01020304";
    bytes buyer2PubKey = hex"05060708";

    function setUp() public {
        store = new ZkRevealStore();
        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(buyer2, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _createListingAsSeller() internal returns (uint256 listingId) {
        vm.prank(seller);
        listingId = store.createListing(title, unitPrice, refundWindow);
    }

    function _addInventoryUnitsAsSeller(uint256 listingId, uint256 count) internal {
        vm.prank(seller);
        store.addInventoryUnitsToListing(listingId, count);
    }

    function _createEscrowAs(uint256 listingId, address who, bytes memory pubKey) internal returns (uint256 escrowId) {
        vm.prank(who);
        escrowId = store.createEscrow{value: unitPrice}(listingId, pubKey);
    }

    function _assertInventory(
        uint256 listingId,
        uint256 expectedTotal,
        uint256 expectedSold,
        uint256 expectedRemaining,
        bool expectedSoldOut
    ) internal view {
        (uint256 totalInventoryUnits, uint256 soldInventoryUnits, uint256 remainingInventoryUnits, bool soldOut) =
            store.getListingInventorySummary(listingId);
        assertEq(totalInventoryUnits, expectedTotal);
        assertEq(soldInventoryUnits, expectedSold);
        assertEq(remainingInventoryUnits, expectedRemaining);
        assertEq(soldOut, expectedSoldOut);
    }

    function test_ListingCreated_Emits() public {
        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.ListingCreated(1, seller, title, unitPrice, refundWindow);

        vm.prank(seller);
        store.createListing(title, unitPrice, refundWindow);
    }

    function test_CreateListing_SetsFields() public {
        uint256 listingId = _createListingAsSeller();

        ZkRevealStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.seller, seller);
        assertEq(listing.title, title);
        assertEq(listing.unitPrice, unitPrice);
        assertEq(listing.refundWindow, refundWindow);
        assertEq(listing.active, true);
        assertEq(listing.nextInventoryUnitIndex, 0);
        assertEq(listing.totalInventoryUnits, 0);
        assertEq(listing.soldInventoryUnits, 0);

        uint256[] memory ids = store.getListingsBySeller(seller);
        assertEq(ids.length, 1);
        assertEq(ids[0], listingId);
    }

    function test_CreateListing_TracksMultipleListingsBySeller() public {
        uint256 listingId1 = _createListingAsSeller();
        uint256 listingId2 = _createListingAsSeller();

        uint256[] memory ids = store.getListingsBySeller(seller);
        assertEq(ids.length, 2);
        assertEq(ids[0], listingId1);
        assertEq(ids[1], listingId2);
    }

    function test_CreateListingInvalidParams_Reverts() public {
        uint64 tooShort = store.MIN_REFUND_WINDOW() - 1;
        uint64 tooLong = store.MAX_REFUND_WINDOW() + 1;

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createListing("", unitPrice, refundWindow);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createListing(title, 0, refundWindow);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createListing(title, unitPrice, tooShort);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createListing(title, unitPrice, tooLong);
    }

    function test_AddInventoryUnitsToListing_AppendsInventory() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.InventoryUnitAdded(listingId, 3);

        _addInventoryUnitsAsSeller(listingId, 3);

        uint256[] memory inventoryUnitIds = store.getListingInventoryUnitIds(listingId);
        assertEq(inventoryUnitIds.length, 3);

        ZkRevealStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.totalInventoryUnits, 3);
        assertEq(listing.soldInventoryUnits, 0);

        ZkRevealStore.InventoryUnit memory inventoryUnit0 = store.getInventoryUnit(inventoryUnitIds[0]);
        ZkRevealStore.InventoryUnit memory inventoryUnit1 = store.getInventoryUnit(inventoryUnitIds[1]);
        ZkRevealStore.InventoryUnit memory inventoryUnit2 = store.getInventoryUnit(inventoryUnitIds[2]);

        assertEq(inventoryUnit0.listingId, listingId);
        assertEq(inventoryUnit0.contentCID, "");
        assertEq(inventoryUnit0.consumed, false);

        assertEq(inventoryUnit1.listingId, listingId);
        assertEq(inventoryUnit1.contentCID, "");
        assertEq(inventoryUnit1.consumed, false);

        assertEq(inventoryUnit2.listingId, listingId);
        assertEq(inventoryUnit2.contentCID, "");
        assertEq(inventoryUnit2.consumed, false);
    }

    function test_AddInventoryUnitsToListing_ZeroCountReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.addInventoryUnitsToListing(listingId, 0);
    }

    function test_AddInventoryUnitsToListing_NonexistentListingReverts() public {
        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.ListingNotFound.selector);
        store.addInventoryUnitsToListing(999, 1);
    }

    function test_Permissions_NonSellerCannotAddInventoryUnits() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotListingSeller.selector);
        store.addInventoryUnitsToListing(listingId, 1);
    }

    function test_SetListingActive_TogglesAndBlocksEscrowCreation() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.ListingStatusChanged(listingId, false);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ListingInactive.selector);
        store.createEscrow{value: unitPrice}(listingId, buyerPubKey);

        vm.prank(seller);
        store.setListingActive(listingId, true);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);
        assertEq(escrowId, 1);
    }

    function test_Permissions_NonSellerCannotToggleListingStatus() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotListingSeller.selector);
        store.setListingActive(listingId, false);
    }

    function test_CreateEscrow_AllocatesAndCreatesEscrow() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 2);

        uint256 buyerBalBefore = buyer.balance;

        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.EscrowCreated(1, listingId, 1, seller, buyer, unitPrice);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);
        assertEq(escrowId, 1);

        ZkRevealStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(escrow.listingId, listingId);
        assertEq(escrow.inventoryUnitId, 1);
        assertEq(escrow.seller, seller);
        assertEq(escrow.buyer, buyer);
        assertEq(escrow.amount, unitPrice);
        assertEq(escrow.buyerPubKey, buyerPubKey);
        assertEq(uint8(escrow.status), uint8(ZkRevealStore.EscrowStatus.Pending));
        assertEq(escrow.deadline, escrow.createdAt + refundWindow);

        ZkRevealStore.InventoryUnit memory inventoryUnit = store.getInventoryUnit(1);
        assertEq(inventoryUnit.contentCID, "");
        assertEq(inventoryUnit.consumed, true);

        assertEq(buyer.balance, buyerBalBefore - unitPrice);
        assertEq(address(store).balance, unitPrice);

        ZkRevealStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.soldInventoryUnits, 1);
        assertEq(listing.nextInventoryUnitIndex, 1);
        assertEq(store.getListingRemainingInventoryUnits(listingId), 1);
    }

    function test_CreateEscrow_SequentialAllocation() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 3);

        uint256 escrowId1 = _createEscrowAs(listingId, buyer, buyerPubKey);
        uint256 escrowId2 = _createEscrowAs(listingId, buyer2, buyer2PubKey);

        assertEq(store.getEscrow(escrowId1).inventoryUnitId, 1);
        assertEq(store.getEscrow(escrowId2).inventoryUnitId, 2);

        ZkRevealStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.soldInventoryUnits, 2);
        assertEq(listing.nextInventoryUnitIndex, 2);
        assertEq(store.getListingRemainingInventoryUnits(listingId), 1);
    }

    function test_CreateEscrow_SoldOutReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(buyer2);
        vm.expectRevert(ZkRevealStore.SoldOut.selector);
        store.createEscrow{value: unitPrice}(listingId, buyer2PubKey);
    }

    function test_CreateEscrow_BadPriceReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadPrice.selector);
        store.createEscrow{value: unitPrice - 1}(listingId, buyerPubKey);
    }

    function test_CreateEscrow_EmptyPubKeyReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createEscrow{value: unitPrice}(listingId, "");
    }

    function test_CreateEscrow_NonexistentListingReverts() public {
        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ListingNotFound.selector);
        store.createEscrow{value: unitPrice}(999, buyerPubKey);
    }

    function test_Permissions_NonSellerCannotDeliverEscrow() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotEscrowSeller.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");
    }

    function test_DeliverEscrow_EmptyEncryptedKeyReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.EmptyValue.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", "");
    }

    function test_DeliverEscrow_EmptyContentCIDReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.EmptyValue.selector);
        store.deliverEscrow(escrowId, "", hex"aa");
    }

    function test_DeliverEscrow_HappyPathPaysSeller() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);
        uint256 sellerBalBefore = seller.balance;

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.EscrowDelivered(escrowId);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"deadbeef");

        ZkRevealStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(uint8(escrow.status), uint8(ZkRevealStore.EscrowStatus.Delivered));
        assertEq(escrow.encryptedKey, hex"deadbeef");

        ZkRevealStore.InventoryUnit memory inventoryUnit = store.getInventoryUnit(escrow.inventoryUnitId);
        assertEq(inventoryUnit.contentCID, "ipfs://cid-1");

        assertEq(seller.balance, sellerBalBefore + unitPrice);
        assertEq(address(store).balance, 0);
    }

    function test_DeliverEscrow_AtDeadlineSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;

        vm.warp(uint256(deadline));

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        assertEq(uint8(store.getEscrow(escrowId).status), uint8(ZkRevealStore.EscrowStatus.Delivered));
        assertEq(store.getInventoryUnit(store.getEscrow(escrowId).inventoryUnitId).contentCID, "ipfs://cid-1");
    }

    function test_DeliverEscrow_CannotDeliverTwice() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-2", hex"bb");
    }

    function test_DeliverEscrow_AfterDeadlineReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.DeadlinePassed.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");
    }

    function test_Getters_NonexistentIdsRevert() public {
        vm.expectRevert(ZkRevealStore.ListingNotFound.selector);
        store.getListing(999);

        vm.expectRevert(ZkRevealStore.InventoryUnitNotFound.selector);
        store.getInventoryUnit(999);

        vm.expectRevert(ZkRevealStore.EscrowNotFound.selector);
        store.getEscrow(999);
    }

    function test_Permissions_NonBuyerCannotReclaim() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotEscrowBuyer.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_AfterDeadlineRefundsBuyer() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 buyerBalBefore = buyer.balance;
        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.EscrowReclaimed(escrowId);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        ZkRevealStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(uint8(escrow.status), uint8(ZkRevealStore.EscrowStatus.Reclaimed));
        assertEq(buyer.balance, buyerBalBefore);

        // Consumed inventory stays consumed (no recycle)
        ZkRevealStore.InventoryUnit memory inventoryUnit = store.getInventoryUnit(escrow.inventoryUnitId);
        assertEq(inventoryUnit.contentCID, "");
        assertEq(inventoryUnit.consumed, true);
        assertEq(store.getListingRemainingInventoryUnits(listingId), 0);
    }

    function test_ReclaimEscrow_BeforeDeadlineReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.DeadlineNotPassed.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_CannotReclaimTwice() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_AfterDeliveryReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _createEscrowAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        vm.warp(uint256(store.getEscrow(escrowId).deadline) + 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ViewHelpers_InventorySummary() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 2);

        _assertInventory(listingId, 2, 0, 2, false);

        _createEscrowAs(listingId, buyer, buyerPubKey);

        _assertInventory(listingId, 2, 1, 1, false);

        _createEscrowAs(listingId, buyer2, buyer2PubKey);

        _assertInventory(listingId, 2, 2, 0, true);
        assertEq(store.isListingSoldOut(listingId), true);
    }
}
