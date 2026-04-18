// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevealDeliveryStore} from "../src/RevealDeliveryStore.sol";

contract RevealDeliveryStoreTest is Test {
    RevealDeliveryStore store;

    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    address buyer2 = address(0xCAFE);
    address attacker = address(0xD00D);

    string title = "Pro Dataset";
    string resourceId = "dataset/btc-signals-mar-2026";
    uint256 unitPrice = 0.1 ether;
    uint64 refundWindow = 1 hours;
    bytes buyerPubKey = hex"01020304";
    bytes buyer2PubKey = hex"05060708";

    function setUp() public {
        store = new RevealDeliveryStore();
        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(buyer2, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _createListingAsSeller() internal returns (uint256 listingId) {
        vm.prank(seller);
        listingId = store.createListing(title, resourceId, unitPrice, refundWindow);
    }

    function _addInventoryUnitsAsSeller(uint256 listingId, uint256 count) internal {
        vm.prank(seller);
        store.addInventoryUnitsToListing(listingId, count);
    }

    function _purchaseDeliveryAs(uint256 listingId, address who, bytes memory pubKey) internal returns (uint256 escrowId) {
        vm.prank(who);
        escrowId = store.purchaseDelivery{value: unitPrice}(listingId, pubKey);
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
        vm.expectEmit(true, true, false, true);
        emit RevealDeliveryStore.ListingCreated(1, seller, title, resourceId, unitPrice, refundWindow);

        vm.prank(seller);
        store.createListing(title, resourceId, unitPrice, refundWindow);
    }

    function test_CreateListing_SetsFields() public {
        uint256 listingId = _createListingAsSeller();

        RevealDeliveryStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.seller, seller);
        assertEq(listing.title, title);
        assertEq(listing.resourceId, resourceId);
        assertEq(listing.unitPrice, unitPrice);
        assertEq(listing.refundWindow, refundWindow);
        assertEq(listing.active, true);
        assertEq(listing.nextInventoryUnitIndex, 0);
        assertEq(listing.totalInventoryUnits, 0);
        assertEq(listing.soldInventoryUnits, 0);

        (
            address listingSeller,
            string memory listingTitle,
            string memory listingResourceId,
            uint256 listingUnitPrice,
            uint64 listingRefundWindow,
            bool listingActive,
            uint256 nextInventoryUnitIndex,
            uint256 totalInventoryUnits,
            uint256 soldInventoryUnits
        ) = store.listings(listingId);
        assertEq(listingSeller, seller);
        assertEq(listingTitle, title);
        assertEq(listingResourceId, resourceId);
        assertEq(listingUnitPrice, unitPrice);
        assertEq(listingRefundWindow, refundWindow);
        assertEq(listingActive, true);
        assertEq(nextInventoryUnitIndex, 0);
        assertEq(totalInventoryUnits, 0);
        assertEq(soldInventoryUnits, 0);

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

    function test_CreateListing_AllowsWhitespaceOnlyResourceId() public {
        vm.prank(seller);
        uint256 listingId = store.createListing(title, "   ", unitPrice, refundWindow);

        RevealDeliveryStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.resourceId, "   ");

        (,, string memory listingResourceId,,,,,,) = store.listings(listingId);
        assertEq(listingResourceId, "   ");
    }

    function test_CreateListingInvalidParams_Reverts() public {
        uint64 tooShort = store.MIN_REFUND_WINDOW() - 1;
        uint64 tooLong = store.MAX_REFUND_WINDOW() + 1;

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.createListing("", resourceId, unitPrice, refundWindow);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.createListing(title, "", unitPrice, refundWindow);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.createListing(title, resourceId, 0, refundWindow);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.createListing(title, resourceId, unitPrice, tooShort);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.createListing(title, resourceId, unitPrice, tooLong);
    }

    function test_AddInventoryUnitsToListing_AppendsInventory() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, false, false, true);
        emit RevealDeliveryStore.InventoryUnitAdded(listingId, 3);

        _addInventoryUnitsAsSeller(listingId, 3);

        uint256[] memory inventoryUnitIds = store.getListingInventoryUnitIds(listingId);
        assertEq(inventoryUnitIds.length, 3);

        RevealDeliveryStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.totalInventoryUnits, 3);
        assertEq(listing.soldInventoryUnits, 0);

        RevealDeliveryStore.InventoryUnit memory inventoryUnit0 = store.getInventoryUnit(inventoryUnitIds[0]);
        RevealDeliveryStore.InventoryUnit memory inventoryUnit1 = store.getInventoryUnit(inventoryUnitIds[1]);
        RevealDeliveryStore.InventoryUnit memory inventoryUnit2 = store.getInventoryUnit(inventoryUnitIds[2]);

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
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.addInventoryUnitsToListing(listingId, 0);
    }

    function test_AddInventoryUnitsToListing_NonexistentListingReverts() public {
        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.ListingNotFound.selector);
        store.addInventoryUnitsToListing(999, 1);
    }

    function test_Permissions_NonSellerCannotAddInventoryUnits() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(RevealDeliveryStore.NotListingSeller.selector);
        store.addInventoryUnitsToListing(listingId, 1);
    }

    function test_SetListingActive_TogglesAndBlocksPurchases() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        vm.expectEmit(true, false, false, true);
        emit RevealDeliveryStore.ListingStatusChanged(listingId, false);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.ListingInactive.selector);
        store.purchaseDelivery{value: unitPrice}(listingId, buyerPubKey);

        vm.prank(seller);
        store.setListingActive(listingId, true);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);
        assertEq(escrowId, 1);
    }

    function test_Permissions_NonSellerCannotToggleListingStatus() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(RevealDeliveryStore.NotListingSeller.selector);
        store.setListingActive(listingId, false);
    }

    function test_PurchaseDelivery_AllocatesAndCreatesEscrow() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 2);

        uint256 buyerBalBefore = buyer.balance;

        vm.expectEmit(true, true, true, true);
        emit RevealDeliveryStore.EscrowCreated(1, listingId, 1, seller, buyer, unitPrice, resourceId);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);
        assertEq(escrowId, 1);

        RevealDeliveryStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(escrow.listingId, listingId);
        assertEq(escrow.inventoryUnitId, 1);
        assertEq(escrow.seller, seller);
        assertEq(escrow.buyer, buyer);
        assertEq(escrow.amount, unitPrice);
        assertEq(escrow.buyerPubKey, buyerPubKey);
        assertEq(uint8(escrow.status), uint8(RevealDeliveryStore.EscrowStatus.Pending));
        assertEq(escrow.deadline, escrow.createdAt + refundWindow);

        RevealDeliveryStore.InventoryUnit memory inventoryUnit = store.getInventoryUnit(1);
        assertEq(inventoryUnit.contentCID, "");
        assertEq(inventoryUnit.consumed, true);

        assertEq(buyer.balance, buyerBalBefore - unitPrice);
        assertEq(address(store).balance, unitPrice);

        RevealDeliveryStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.soldInventoryUnits, 1);
        assertEq(listing.nextInventoryUnitIndex, 1);
        assertEq(store.getListingRemainingInventoryUnits(listingId), 1);
    }

    function test_PurchaseDelivery_SequentialAllocation() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 3);

        uint256 escrowId1 = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);
        uint256 escrowId2 = _purchaseDeliveryAs(listingId, buyer2, buyer2PubKey);

        assertEq(store.getEscrow(escrowId1).inventoryUnitId, 1);
        assertEq(store.getEscrow(escrowId2).inventoryUnitId, 2);

        RevealDeliveryStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.soldInventoryUnits, 2);
        assertEq(listing.nextInventoryUnitIndex, 2);
        assertEq(store.getListingRemainingInventoryUnits(listingId), 1);
    }

    function test_PurchaseDelivery_SoldOutReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(buyer2);
        vm.expectRevert(RevealDeliveryStore.SoldOut.selector);
        store.purchaseDelivery{value: unitPrice}(listingId, buyer2PubKey);
    }

    function test_PurchaseDelivery_BadPriceReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.BadPrice.selector);
        store.purchaseDelivery{value: unitPrice - 1}(listingId, buyerPubKey);
    }

    function test_PurchaseDelivery_EmptyPubKeyReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.InvalidParams.selector);
        store.purchaseDelivery{value: unitPrice}(listingId, "");
    }

    function test_PurchaseDelivery_NonexistentListingReverts() public {
        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.ListingNotFound.selector);
        store.purchaseDelivery{value: unitPrice}(999, buyerPubKey);
    }

    function test_Permissions_NonSellerCannotDeliverEscrow() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(attacker);
        vm.expectRevert(RevealDeliveryStore.NotEscrowSeller.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");
    }

    function test_DeliverEscrow_EmptyEncryptedKeyReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.EmptyValue.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", "");
    }

    function test_DeliverEscrow_EmptyContentCIDReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.EmptyValue.selector);
        store.deliverEscrow(escrowId, "", hex"aa");
    }

    function test_DeliverEscrow_HappyPathPaysSeller() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);
        uint256 sellerBalBefore = seller.balance;

        vm.expectEmit(true, true, true, true);
        emit RevealDeliveryStore.EscrowDelivered(escrowId, listingId, buyer, resourceId, "ipfs://cid-1");

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"deadbeef");

        RevealDeliveryStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(uint8(escrow.status), uint8(RevealDeliveryStore.EscrowStatus.Delivered));
        assertEq(escrow.encryptedKey, hex"deadbeef");

        RevealDeliveryStore.InventoryUnit memory inventoryUnit = store.getInventoryUnit(escrow.inventoryUnitId);
        assertEq(inventoryUnit.contentCID, "ipfs://cid-1");

        assertEq(seller.balance, sellerBalBefore + unitPrice);
        assertEq(address(store).balance, 0);
    }

    function test_DeliverEscrow_AtDeadlineSucceeds() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;

        vm.warp(uint256(deadline));

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        assertEq(uint8(store.getEscrow(escrowId).status), uint8(RevealDeliveryStore.EscrowStatus.Delivered));
        assertEq(store.getInventoryUnit(store.getEscrow(escrowId).inventoryUnitId).contentCID, "ipfs://cid-1");
    }

    function test_DeliverEscrow_CannotDeliverTwice() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.BadState.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-2", hex"bb");
    }

    function test_DeliverEscrow_AfterDeadlineReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(RevealDeliveryStore.DeadlinePassed.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");
    }

    function test_Getters_NonexistentIdsRevert() public {
        vm.expectRevert(RevealDeliveryStore.ListingNotFound.selector);
        store.getListing(999);

        vm.expectRevert(RevealDeliveryStore.InventoryUnitNotFound.selector);
        store.getInventoryUnit(999);

        vm.expectRevert(RevealDeliveryStore.EscrowNotFound.selector);
        store.getEscrow(999);
    }

    function test_Permissions_NonBuyerCannotReclaim() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(attacker);
        vm.expectRevert(RevealDeliveryStore.NotEscrowBuyer.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_AfterDeadlineRefundsBuyer() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 buyerBalBefore = buyer.balance;
        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.expectEmit(true, true, true, true);
        emit RevealDeliveryStore.EscrowReclaimed(escrowId, listingId, buyer, resourceId);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        RevealDeliveryStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(uint8(escrow.status), uint8(RevealDeliveryStore.EscrowStatus.Reclaimed));
        assertEq(buyer.balance, buyerBalBefore);

        // Consumed inventory stays consumed (no recycle)
        RevealDeliveryStore.InventoryUnit memory inventoryUnit = store.getInventoryUnit(escrow.inventoryUnitId);
        assertEq(inventoryUnit.contentCID, "");
        assertEq(inventoryUnit.consumed, true);
        assertEq(store.getListingRemainingInventoryUnits(listingId), 0);
    }

    function test_ReclaimEscrow_BeforeDeadlineReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.DeadlineNotPassed.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_CannotReclaimTwice() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_AfterDeliveryReverts() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 1);

        uint256 escrowId = _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        vm.warp(uint256(store.getEscrow(escrowId).deadline) + 1);

        vm.prank(buyer);
        vm.expectRevert(RevealDeliveryStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ViewHelpers_InventorySummary() public {
        uint256 listingId = _createListingAsSeller();
        _addInventoryUnitsAsSeller(listingId, 2);

        _assertInventory(listingId, 2, 0, 2, false);

        _purchaseDeliveryAs(listingId, buyer, buyerPubKey);

        _assertInventory(listingId, 2, 1, 1, false);

        _purchaseDeliveryAs(listingId, buyer2, buyer2PubKey);

        _assertInventory(listingId, 2, 2, 0, true);
        assertEq(store.isListingSoldOut(listingId), true);
    }
}
