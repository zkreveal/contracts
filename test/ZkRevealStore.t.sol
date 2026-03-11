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

    function _createProductAsSeller() internal returns (uint256 productId) {
        vm.prank(seller);
        productId = store.createProduct(title, unitPrice, refundWindow);
    }

    function _addItemsAsSeller(uint256 productId, uint256 count) internal {
        vm.prank(seller);
        store.addItemsToProduct(productId, count);
    }

    function _createEscrowAs(uint256 productId, address who, bytes memory pubKey) internal returns (uint256 escrowId) {
        vm.prank(who);
        escrowId = store.createEscrow{value: unitPrice}(productId, pubKey);
    }

    function _assertInventory(
        uint256 productId,
        uint256 expectedTotal,
        uint256 expectedSold,
        uint256 expectedRemaining,
        bool expectedSoldOut
    ) internal view {
        (uint256 totalItems, uint256 soldItems, uint256 remainingItems, bool soldOut) =
            store.getProductInventorySummary(productId);
        assertEq(totalItems, expectedTotal);
        assertEq(soldItems, expectedSold);
        assertEq(remainingItems, expectedRemaining);
        assertEq(soldOut, expectedSoldOut);
    }

    function test_ProductCreated_Emits() public {
        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.ProductCreated(1, seller, title, unitPrice, refundWindow);

        vm.prank(seller);
        store.createProduct(title, unitPrice, refundWindow);
    }

    function test_CreateProduct_SetsFields() public {
        uint256 productId = _createProductAsSeller();

        ZkRevealStore.Product memory product = store.getProduct(productId);
        assertEq(product.seller, seller);
        assertEq(product.title, title);
        assertEq(product.unitPrice, unitPrice);
        assertEq(product.refundWindow, refundWindow);
        assertEq(product.active, true);
        assertEq(product.nextItemIndex, 0);
        assertEq(product.totalItems, 0);
        assertEq(product.soldItems, 0);

        uint256[] memory ids = store.getProductsBySeller(seller);
        assertEq(ids.length, 1);
        assertEq(ids[0], productId);
    }

    function test_CreateProduct_TracksMultipleProductsBySeller() public {
        uint256 productId1 = _createProductAsSeller();
        uint256 productId2 = _createProductAsSeller();

        uint256[] memory ids = store.getProductsBySeller(seller);
        assertEq(ids.length, 2);
        assertEq(ids[0], productId1);
        assertEq(ids[1], productId2);
    }

    function test_CreateProductInvalidParams_Reverts() public {
        uint64 tooShort = store.MIN_REFUND_WINDOW() - 1;
        uint64 tooLong = store.MAX_REFUND_WINDOW() + 1;

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createProduct("", unitPrice, refundWindow);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createProduct(title, 0, refundWindow);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createProduct(title, unitPrice, tooShort);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createProduct(title, unitPrice, tooLong);
    }

    function test_AddItems_AppendsInventory() public {
        uint256 productId = _createProductAsSeller();

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.ProductItemsAdded(productId, 3);

        _addItemsAsSeller(productId, 3);

        uint256[] memory itemIds = store.getProductItemIds(productId);
        assertEq(itemIds.length, 3);

        ZkRevealStore.Product memory product = store.getProduct(productId);
        assertEq(product.totalItems, 3);
        assertEq(product.soldItems, 0);

        ZkRevealStore.ProductItem memory i0 = store.getProductItem(itemIds[0]);
        ZkRevealStore.ProductItem memory i1 = store.getProductItem(itemIds[1]);
        ZkRevealStore.ProductItem memory i2 = store.getProductItem(itemIds[2]);

        assertEq(i0.productId, productId);
        assertEq(i0.contentCID, "");
        assertEq(i0.consumed, false);

        assertEq(i1.productId, productId);
        assertEq(i1.contentCID, "");
        assertEq(i1.consumed, false);

        assertEq(i2.productId, productId);
        assertEq(i2.contentCID, "");
        assertEq(i2.consumed, false);
    }

    function test_AddItems_ZeroCountReverts() public {
        uint256 productId = _createProductAsSeller();

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.addItemsToProduct(productId, 0);
    }

    function test_AddItems_NonexistentProductReverts() public {
        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.ProductNotFound.selector);
        store.addItemsToProduct(999, 1);
    }

    function test_Permissions_NonSellerCannotAddItems() public {
        uint256 productId = _createProductAsSeller();

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotProductSeller.selector);
        store.addItemsToProduct(productId, 1);
    }

    function test_SetProductActive_TogglesAndBlocksEscrowCreation() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.ProductStatusChanged(productId, false);

        vm.prank(seller);
        store.setProductActive(productId, false);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ProductInactive.selector);
        store.createEscrow{value: unitPrice}(productId, buyerPubKey);

        vm.prank(seller);
        store.setProductActive(productId, true);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);
        assertEq(escrowId, 1);
    }

    function test_Permissions_NonSellerCannotToggleProductStatus() public {
        uint256 productId = _createProductAsSeller();

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotProductSeller.selector);
        store.setProductActive(productId, false);
    }

    function test_CreateEscrow_AllocatesAndCreatesEscrow() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 2);

        uint256 buyerBalBefore = buyer.balance;

        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.EscrowCreated(1, productId, 1, seller, buyer, unitPrice);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);
        assertEq(escrowId, 1);

        ZkRevealStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(escrow.productId, productId);
        assertEq(escrow.itemId, 1);
        assertEq(escrow.seller, seller);
        assertEq(escrow.buyer, buyer);
        assertEq(escrow.amount, unitPrice);
        assertEq(escrow.buyerPubKey, buyerPubKey);
        assertEq(uint8(escrow.status), uint8(ZkRevealStore.EscrowStatus.Pending));
        assertEq(escrow.deadline, escrow.createdAt + refundWindow);

        ZkRevealStore.ProductItem memory productItem = store.getProductItem(1);
        assertEq(productItem.contentCID, "");
        assertEq(productItem.consumed, true);

        assertEq(buyer.balance, buyerBalBefore - unitPrice);
        assertEq(address(store).balance, unitPrice);

        ZkRevealStore.Product memory product = store.getProduct(productId);
        assertEq(product.soldItems, 1);
        assertEq(product.nextItemIndex, 1);
        assertEq(store.getProductRemainingItems(productId), 1);
    }

    function test_CreateEscrow_SequentialAllocation() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 3);

        uint256 escrowId1 = _createEscrowAs(productId, buyer, buyerPubKey);
        uint256 escrowId2 = _createEscrowAs(productId, buyer2, buyer2PubKey);

        assertEq(store.getEscrow(escrowId1).itemId, 1);
        assertEq(store.getEscrow(escrowId2).itemId, 2);

        ZkRevealStore.Product memory product = store.getProduct(productId);
        assertEq(product.soldItems, 2);
        assertEq(product.nextItemIndex, 2);
        assertEq(store.getProductRemainingItems(productId), 1);
    }

    function test_CreateEscrow_SoldOutReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(buyer2);
        vm.expectRevert(ZkRevealStore.SoldOut.selector);
        store.createEscrow{value: unitPrice}(productId, buyer2PubKey);
    }

    function test_CreateEscrow_BadPriceReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadPrice.selector);
        store.createEscrow{value: unitPrice - 1}(productId, buyerPubKey);
    }

    function test_CreateEscrow_EmptyPubKeyReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createEscrow{value: unitPrice}(productId, "");
    }

    function test_CreateEscrow_NonexistentProductReverts() public {
        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ProductNotFound.selector);
        store.createEscrow{value: unitPrice}(999, buyerPubKey);
    }

    function test_Permissions_NonSellerCannotDeliverEscrow() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotEscrowSeller.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");
    }

    function test_DeliverEscrow_EmptyEncryptedKeyReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.EmptyValue.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", "");
    }

    function test_DeliverEscrow_EmptyContentCIDReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.EmptyValue.selector);
        store.deliverEscrow(escrowId, "", hex"aa");
    }

    function test_DeliverEscrow_HappyPathPaysSeller() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);
        uint256 sellerBalBefore = seller.balance;

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.EscrowDelivered(escrowId);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"deadbeef");

        ZkRevealStore.Escrow memory escrow = store.getEscrow(escrowId);
        assertEq(uint8(escrow.status), uint8(ZkRevealStore.EscrowStatus.Delivered));
        assertEq(escrow.encryptedKey, hex"deadbeef");

        ZkRevealStore.ProductItem memory productItem = store.getProductItem(escrow.itemId);
        assertEq(productItem.contentCID, "ipfs://cid-1");

        assertEq(seller.balance, sellerBalBefore + unitPrice);
        assertEq(address(store).balance, 0);
    }

    function test_DeliverEscrow_AtDeadlineSucceeds() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;

        vm.warp(uint256(deadline));

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        assertEq(uint8(store.getEscrow(escrowId).status), uint8(ZkRevealStore.EscrowStatus.Delivered));
        assertEq(store.getProductItem(store.getEscrow(escrowId).itemId).contentCID, "ipfs://cid-1");
    }

    function test_DeliverEscrow_CannotDeliverTwice() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-2", hex"bb");
    }

    function test_DeliverEscrow_AfterDeadlineReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.DeadlinePassed.selector);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");
    }

    function test_Getters_NonexistentIdsRevert() public {
        vm.expectRevert(ZkRevealStore.ProductNotFound.selector);
        store.getProduct(999);

        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.getProductItem(999);

        vm.expectRevert(ZkRevealStore.EscrowNotFound.selector);
        store.getEscrow(999);
    }

    function test_Permissions_NonBuyerCannotReclaim() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotEscrowBuyer.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_AfterDeadlineRefundsBuyer() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 buyerBalBefore = buyer.balance;
        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

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
        ZkRevealStore.ProductItem memory productItem = store.getProductItem(escrow.itemId);
        assertEq(productItem.contentCID, "");
        assertEq(productItem.consumed, true);
        assertEq(store.getProductRemainingItems(productId), 0);
    }

    function test_ReclaimEscrow_BeforeDeadlineReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.DeadlineNotPassed.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_CannotReclaimTwice() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimEscrow_AfterDeliveryReverts() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 1);

        uint256 escrowId = _createEscrowAs(productId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, "ipfs://cid-1", hex"aa");

        vm.warp(uint256(store.getEscrow(escrowId).deadline) + 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ViewHelpers_InventorySummary() public {
        uint256 productId = _createProductAsSeller();
        _addItemsAsSeller(productId, 2);

        _assertInventory(productId, 2, 0, 2, false);

        _createEscrowAs(productId, buyer, buyerPubKey);

        _assertInventory(productId, 2, 1, 1, false);

        _createEscrowAs(productId, buyer2, buyer2PubKey);

        _assertInventory(productId, 2, 2, 0, true);
        assertEq(store.isProductSoldOut(productId), true);
    }
}
