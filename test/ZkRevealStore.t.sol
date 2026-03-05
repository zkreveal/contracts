// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkRevealStore} from "../src/ZkRevealStore.sol";

contract ZkRevealStoreTest is Test {
    ZkRevealStore store;

    address seller = address(0xA11CE);
    address buyer = address(0xB0B);

    uint256 price = 0.1 ether;
    string uri = "ipfs://ciphertext.json";
    bytes32 buyerPubKeyHash = keccak256("buyer-pubkey-commitment");
    uint64 refundWindow = 1 hours;

    function setUp() public {
        store = new ZkRevealStore();

        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function _createItemAsSeller() internal returns (uint256 itemId) {
        vm.prank(seller);
        itemId = store.createItem(price, uri);
    }

    function _buyAsBuyer(uint256 itemId) internal {
        vm.prank(buyer);
        store.buy{value: price}(itemId, buyerPubKeyHash, refundWindow);
    }

    // 1) create → buy → reveal (seller gets paid)
    function test_HappyPath_RevealPaysSeller() public {
        uint256 id = _createItemAsSeller();

        uint256 sellerBalBefore = seller.balance;

        _buyAsBuyer(id);

        // Seller commits delivery before deadline => seller paid immediately
        bytes32 deliveryHash = keccak256("ek-delivery-commitment");

        vm.prank(seller);
        store.commitDelivery(id, deliveryHash);

        assertEq(uint8(store.getState(id)), uint8(ZkRevealStore.State.Committed));
        assertEq(seller.balance, sellerBalBefore + price);

        // delivery hash stored
        assertEq(store.getDeliveryHash(id), deliveryHash);
    }

    // 2) create → buy → refund after deadline (buyer gets paid)
    function test_RefundAfterDeadlinePaysBuyer() public {
        uint256 id = _createItemAsSeller();

        uint256 buyerBalBefore = buyer.balance;

        _buyAsBuyer(id);

        // Move time forward past deadline
        uint64 deadline = store.getDeadline(id);
        vm.warp(uint256(deadline) + 1);

        vm.prank(buyer);
        store.refund(id);

        assertEq(uint8(store.getState(id)), uint8(ZkRevealStore.State.Refunded));
        assertEq(buyer.balance, buyerBalBefore); // buyer paid then refunded back
    }

    // 3) refund before deadline reverts
    function test_RefundBeforeDeadlineReverts() public {
        uint256 id = _createItemAsSeller();

        _buyAsBuyer(id);

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.DeadlineNotPassed.selector);
        store.refund(id);
    }

    // 4) reveal after deadline reverts
    function test_RevealAfterDeadlineReverts() public {
        uint256 id = _createItemAsSeller();

        _buyAsBuyer(id);

        uint64 deadline = store.getDeadline(id);
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.DeadlinePassed.selector);
        store.commitDelivery(id, keccak256("late-delivery"));
    }

    // 5) nonexistent item reverts (ItemNotFound)
    function test_ItemNotFound_RevertsOnBuy() public {
        uint256 fakeId = 999999;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.buy{value: price}(fakeId, buyerPubKeyHash, refundWindow);
    }

    function test_ItemNotFound_RevertsOnReveal() public {
        uint256 fakeId = 999999;

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.commitDelivery(fakeId, keccak256("missing-item"));
    }

    function test_ItemNotFound_RevertsOnRefund() public {
        uint256 fakeId = 999999;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.refund(fakeId);
    }

    // Extra (recommended): onlySeller / onlyBuyer guards
    function test_OnlySeller_CannotCancelIfNotSeller() public {
        uint256 id = _createItemAsSeller();

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.NotSeller.selector);
        store.cancelItem(id);
    }

    function test_OnlyBuyer_CannotRefundIfNotBuyer() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        uint64 deadline = store.getDeadline(id);
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.NotBuyer.selector);
        store.refund(id);
    }

    // Extra (recommended): bad price / invalid params
    function test_BuyBadPrice_Reverts() public {
        uint256 id = _createItemAsSeller();

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadPrice.selector);
        store.buy{value: price - 1}(id, buyerPubKeyHash, refundWindow);
    }

    function test_BuyZeroPubKeyHash_Reverts() public {
        uint256 id = _createItemAsSeller();

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, bytes32(0), refundWindow);
    }

    function test_BuyRefundWindowTooShort_Reverts() public {
        uint256 id = _createItemAsSeller();
        uint64 tooShort = store.MIN_REFUND_WINDOW() - 1;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, buyerPubKeyHash, tooShort);
    }

    function test_BuyRefundWindowTooLong_Reverts() public {
        uint256 id = _createItemAsSeller();
        uint64 tooLong = store.MAX_REFUND_WINDOW() + 1;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, buyerPubKeyHash, tooLong);
    }

    function test_CreateItemInvalidParams_Reverts() public {
        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(0, uri);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(price, "");
    }

    function test_ItemBought_EmitsBuyerPubKeyHash() public {
        uint256 id = _createItemAsSeller();

        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.ItemBought(id, buyer, price, uint64(block.timestamp) + refundWindow, buyerPubKeyHash);

        vm.prank(buyer);
        store.buy{value: price}(id, buyerPubKeyHash, refundWindow);
    }

    function test_DeliveryReceiptHash_CanBeVerifiedOffChain() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        bytes memory ekCiphertext = hex"c001c0de";
        bytes32 salt = keccak256("delivery-salt");

        bytes32 deliveryHash = keccak256(abi.encode(id, buyer, buyerPubKeyHash, ekCiphertext, salt));

        bytes32 canonicalHash = store.hashDeliveryReceipt(id, buyer, buyerPubKeyHash, ekCiphertext, salt);
        assertEq(canonicalHash, deliveryHash);

        vm.prank(seller);
        store.commitDelivery(id, deliveryHash);

        assertEq(store.getDeliveryHash(id), deliveryHash);
    }
}
