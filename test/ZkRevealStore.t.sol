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

    function _addItemsAsSeller(uint256 productId, string[] memory cids) internal {
        vm.prank(seller);
        store.addItemsToProduct(productId, cids);
    }

    function _buyAs(uint256 productId, address who, bytes memory pubKey) internal returns (uint256 escrowId) {
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

        ZkRevealStore.Product memory p = store.getProduct(productId);
        assertEq(p.seller, seller);
        assertEq(p.title, title);
        assertEq(p.unitPrice, unitPrice);
        assertEq(p.refundWindow, refundWindow);
        assertEq(p.active, true);
        assertEq(p.nextItemIndex, 0);
        assertEq(p.totalItems, 0);
        assertEq(p.soldItems, 0);

        uint256[] memory ids = store.getProductsBySeller(seller);
        assertEq(ids.length, 1);
        assertEq(ids[0], productId);
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

        string[] memory cids = new string[](3);
        cids[0] = "ipfs://cid-1";
        cids[1] = "ipfs://cid-2";
        cids[2] = "ipfs://cid-3";

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.ProductItemsAdded(productId, 3);

        _addItemsAsSeller(productId, cids);

        uint256[] memory itemIds = store.getProductItemIds(productId);
        assertEq(itemIds.length, 3);

        ZkRevealStore.Product memory p = store.getProduct(productId);
        assertEq(p.totalItems, 3);
        assertEq(p.soldItems, 0);

        ZkRevealStore.ProductItem memory i0 = store.getProductItem(itemIds[0]);
        ZkRevealStore.ProductItem memory i1 = store.getProductItem(itemIds[1]);
        ZkRevealStore.ProductItem memory i2 = store.getProductItem(itemIds[2]);

        assertEq(i0.productId, productId);
        assertEq(i0.contentCID, "ipfs://cid-1");
        assertEq(i0.consumed, false);

        assertEq(i1.productId, productId);
        assertEq(i1.contentCID, "ipfs://cid-2");
        assertEq(i1.consumed, false);

        assertEq(i2.productId, productId);
        assertEq(i2.contentCID, "ipfs://cid-3");
        assertEq(i2.consumed, false);
    }

    function test_AddItems_InvalidCidReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](2);
        cids[0] = "ipfs://cid-1";
        cids[1] = "";

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.addItemsToProduct(productId, cids);
    }

    function test_Permissions_NonSellerCannotAddItems() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotProductSeller.selector);
        store.addItemsToProduct(productId, cids);
    }

    function test_SetProductActive_TogglesAndBlocksBuy() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.ProductStatusChanged(productId, false);

        vm.prank(seller);
        store.setProductActive(productId, false);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ProductInactive.selector);
        store.createEscrow{value: unitPrice}(productId, buyerPubKey);

        vm.prank(seller);
        store.setProductActive(productId, true);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);
        assertEq(escrowId, 1);
    }

    function test_Permissions_NonSellerCannotToggleProductStatus() public {
        uint256 productId = _createProductAsSeller();

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotProductSeller.selector);
        store.setProductActive(productId, false);
    }

    function test_BuyProduct_AllocatesAndCreatesOrder() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](2);
        cids[0] = "ipfs://cid-1";
        cids[1] = "ipfs://cid-2";
        _addItemsAsSeller(productId, cids);

        uint256 buyerBalBefore = buyer.balance;

        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.EscrowCreated(1, productId, 1, seller, buyer, unitPrice);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);
        assertEq(escrowId, 1);

        ZkRevealStore.Escrow memory o = store.getEscrow(escrowId);
        assertEq(o.productId, productId);
        assertEq(o.itemId, 1);
        assertEq(o.seller, seller);
        assertEq(o.buyer, buyer);
        assertEq(o.amount, unitPrice);
        assertEq(o.buyerPubKey, buyerPubKey);
        assertEq(uint8(o.status), uint8(ZkRevealStore.EscrowStatus.Pending));
        assertEq(o.deadline, o.createdAt + refundWindow);

        ZkRevealStore.ProductItem memory i = store.getProductItem(1);
        assertEq(i.consumed, true);

        assertEq(buyer.balance, buyerBalBefore - unitPrice);
        assertEq(address(store).balance, unitPrice);

        ZkRevealStore.Product memory p = store.getProduct(productId);
        assertEq(p.soldItems, 1);
        assertEq(p.nextItemIndex, 1);
        assertEq(store.getProductRemainingItems(productId), 1);
    }

    function test_BuyProduct_SequentialAllocation() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](3);
        cids[0] = "ipfs://cid-1";
        cids[1] = "ipfs://cid-2";
        cids[2] = "ipfs://cid-3";
        _addItemsAsSeller(productId, cids);

        uint256 order1 = _buyAs(productId, buyer, buyerPubKey);
        uint256 order2 = _buyAs(productId, buyer2, buyer2PubKey);

        assertEq(store.getEscrow(order1).itemId, 1);
        assertEq(store.getEscrow(order2).itemId, 2);

        ZkRevealStore.Product memory p = store.getProduct(productId);
        assertEq(p.soldItems, 2);
        assertEq(p.nextItemIndex, 2);
        assertEq(store.getProductRemainingItems(productId), 1);
    }

    function test_BuyProduct_SoldOutReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        _buyAs(productId, buyer, buyerPubKey);

        vm.prank(buyer2);
        vm.expectRevert(ZkRevealStore.SoldOut.selector);
        store.createEscrow{value: unitPrice}(productId, buyer2PubKey);
    }

    function test_BuyProduct_BadPriceReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadPrice.selector);
        store.createEscrow{value: unitPrice - 1}(productId, buyerPubKey);
    }

    function test_BuyProduct_EmptyPubKeyReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createEscrow{value: unitPrice}(productId, "");
    }

    function test_Permissions_NonSellerCannotSubmitEncryptedKey() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotEscrowSeller.selector);
        store.deliverEscrow(escrowId, hex"aa");
    }

    function test_SubmitEncryptedKey_HappyPathPaysSeller() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);
        uint256 sellerBalBefore = seller.balance;

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.EscrowDelivered(escrowId);

        vm.prank(seller);
        store.deliverEscrow(escrowId, hex"deadbeef");

        ZkRevealStore.Escrow memory o = store.getEscrow(escrowId);
        assertEq(uint8(o.status), uint8(ZkRevealStore.EscrowStatus.Delivered));
        assertEq(o.encryptedKey, hex"deadbeef");

        assertEq(seller.balance, sellerBalBefore + unitPrice);
        assertEq(address(store).balance, 0);
    }

    function test_SubmitEncryptedKey_CannotSubmitTwice() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, hex"aa");

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.deliverEscrow(escrowId, hex"bb");
    }

    function test_SubmitEncryptedKey_AfterDeadlineReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.DeadlinePassed.selector);
        store.deliverEscrow(escrowId, hex"aa");
    }

    function test_Permissions_NonBuyerCannotReclaim() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);
        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(attacker);
        vm.expectRevert(ZkRevealStore.NotEscrowBuyer.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimExpired_AfterDeadlineRefundsBuyer() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 buyerBalBefore = buyer.balance;
        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.EscrowReclaimed(escrowId);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        ZkRevealStore.Escrow memory o = store.getEscrow(escrowId);
        assertEq(uint8(o.status), uint8(ZkRevealStore.EscrowStatus.Reclaimed));
        assertEq(buyer.balance, buyerBalBefore);

        // Consumed inventory stays consumed (no recycle)
        ZkRevealStore.ProductItem memory i = store.getProductItem(o.itemId);
        assertEq(i.consumed, true);
        assertEq(store.getProductRemainingItems(productId), 0);
    }

    function test_ReclaimExpired_BeforeDeadlineReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.DeadlineNotPassed.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimExpired_CannotReclaimTwice() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        uint64 deadline = store.getEscrow(escrowId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(buyer);
        store.reclaimEscrow(escrowId);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ReclaimAfterDeliveryReverts() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](1);
        cids[0] = "ipfs://cid-1";
        _addItemsAsSeller(productId, cids);

        uint256 escrowId = _buyAs(productId, buyer, buyerPubKey);

        vm.prank(seller);
        store.deliverEscrow(escrowId, hex"aa");

        vm.warp(uint256(store.getEscrow(escrowId).deadline) + 1);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.reclaimEscrow(escrowId);
    }

    function test_ViewHelpers_InventorySummary() public {
        uint256 productId = _createProductAsSeller();

        string[] memory cids = new string[](2);
        cids[0] = "ipfs://cid-1";
        cids[1] = "ipfs://cid-2";
        _addItemsAsSeller(productId, cids);

        _assertInventory(productId, 2, 0, 2, false);

        _buyAs(productId, buyer, buyerPubKey);

        _assertInventory(productId, 2, 1, 1, false);

        _buyAs(productId, buyer2, buyer2PubKey);

        _assertInventory(productId, 2, 2, 0, true);
        assertEq(store.isProductSoldOut(productId), true);
    }
}
