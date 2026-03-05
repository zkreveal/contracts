// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkRevealStore} from "../src/ZkRevealStore.sol";

contract ZkRevealStoreTest is Test {
    ZkRevealStore store;

    address seller = address(0xA11CE);
    address buyer = address(0xB0B);

    uint256 price = 0.1 ether;
    string encUriPointer = "ipfs://bafybeihash/encrypted-uri.bin";
    bytes32 encUriPointerHash = keccak256(bytes(encUriPointer));
    bytes32 ciphertextHash = keccak256("ciphertext-blob");
    bytes32 kHash = keccak256("k-hash");
    bytes buyerPubKey = hex"01020304";
    uint64 refundWindow = 1 hours;

    function setUp() public {
        store = new ZkRevealStore();

        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function _createItemAsSeller() internal returns (uint256 itemId) {
        vm.prank(seller);
        itemId = store.createItem(price, encUriPointer, encUriPointerHash, ciphertextHash, kHash);
    }

    function _buyAsBuyer(uint256 itemId) internal {
        vm.prank(buyer);
        store.buy{value: price}(itemId, buyerPubKey, refundWindow);
    }

    function test_ItemCreated_EmitsLockedFields() public {
        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.ItemCreated(1, seller, price, encUriPointerHash, ciphertextHash, kHash);

        vm.prank(seller);
        store.createItem(price, encUriPointer, encUriPointerHash, ciphertextHash, kHash);
    }

    // 1) create → buy → deliver (seller gets paid)
    function test_HappyPath_DeliverPaysSeller() public {
        uint256 id = _createItemAsSeller();

        uint256 sellerBalBefore = seller.balance;

        _buyAsBuyer(id);

        // Seller delivers EK ciphertext before deadline => seller paid immediately
        bytes memory ekCiphertext = hex"deadbeef";

        vm.prank(seller);
        store.deliver(id, buyerPubKey, ekCiphertext);

        assertEq(uint8(store.getState(id)), uint8(ZkRevealStore.State.Committed));
        assertEq(seller.balance, sellerBalBefore + price);

        // EK payload + hash stored
        assertEq(store.getEkHash(id), keccak256(ekCiphertext));
        assertEq(store.getEkCiphertext(id), ekCiphertext);
    }

    function test_ItemDelivered_EmitsLockedFields() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        bytes memory ekCiphertext = hex"deadbeef";
        bytes32 buyerPubKeyHash = keccak256(buyerPubKey);
        bytes32 ekHash = keccak256(ekCiphertext);
        bytes32 deliveryReceiptHash = keccak256(abi.encode(id, buyer, buyerPubKeyHash, ekCiphertext));

        vm.expectEmit(true, false, false, true);
        emit ZkRevealStore.ItemDelivered(id, ekHash, deliveryReceiptHash);

        vm.prank(seller);
        store.deliver(id, buyerPubKey, ekCiphertext);
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

    // 4) deliver after deadline reverts
    function test_DeliverAfterDeadlineReverts() public {
        uint256 id = _createItemAsSeller();

        _buyAsBuyer(id);

        uint64 deadline = store.getDeadline(id);
        vm.warp(uint256(deadline) + 1);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.DeadlinePassed.selector);
        store.deliver(id, buyerPubKey, hex"01");
    }

    // 5) nonexistent item reverts (ItemNotFound)
    function test_ItemNotFound_RevertsOnBuy() public {
        uint256 fakeId = 999999;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.buy{value: price}(fakeId, buyerPubKey, refundWindow);
    }

    function test_ItemNotFound_RevertsOnDeliver() public {
        uint256 fakeId = 999999;

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.deliver(fakeId, buyerPubKey, hex"01");
    }

    function test_ItemNotFound_RevertsOnRefund() public {
        uint256 fakeId = 999999;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.refund(fakeId);
    }

    function test_CancelListed_SetsCancelledAndLocksItem() public {
        uint256 id = _createItemAsSeller();

        vm.prank(seller);
        store.cancelItem(id);
        assertEq(uint8(store.getState(id)), uint8(ZkRevealStore.State.Cancelled));

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.buy{value: price}(id, buyerPubKey, refundWindow);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.deliver(id, buyerPubKey, hex"01");
    }

    function test_CancelAfterBuy_Reverts() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.cancelItem(id);
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
        store.buy{value: price - 1}(id, buyerPubKey, refundWindow);
    }

    function test_BuyEmptyPubKey_Reverts() public {
        uint256 id = _createItemAsSeller();

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, "", refundWindow);
    }

    function test_BuyRefundWindowTooShort_Reverts() public {
        uint256 id = _createItemAsSeller();
        uint64 tooShort = store.MIN_REFUND_WINDOW() - 1;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, buyerPubKey, tooShort);
    }

    function test_BuyRefundWindowTooLong_Reverts() public {
        uint256 id = _createItemAsSeller();
        uint64 tooLong = store.MAX_REFUND_WINDOW() + 1;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, buyerPubKey, tooLong);
    }

    function test_CreateItemInvalidParams_Reverts() public {
        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(0, encUriPointer, encUriPointerHash, ciphertextHash, kHash);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(price, "", encUriPointerHash, ciphertextHash, kHash);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(price, encUriPointer, bytes32(0), ciphertextHash, kHash);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(price, encUriPointer, keccak256("wrong-pointer-hash"), ciphertextHash, kHash);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(price, encUriPointer, encUriPointerHash, bytes32(0), kHash);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.createItem(price, encUriPointer, encUriPointerHash, ciphertextHash, bytes32(0));
    }

    function test_CreateItem_StoresEncUriPointer() public {
        uint256 id = _createItemAsSeller();

        assertEq(store.getEncUriPointer(id), encUriPointer);
        assertEq(store.getEncUriPointerHash(id), encUriPointerHash);
        assertEq(store.getCiphertextHash(id), ciphertextHash);
        assertEq(store.getKHash(id), kHash);
    }

    function test_ItemBought_EmitsBuyerPubKeyHash() public {
        uint256 id = _createItemAsSeller();
        bytes32 buyerPubKeyHash = keccak256(buyerPubKey);

        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.ItemBought(id, buyer, price, uint64(block.timestamp) + refundWindow, buyerPubKeyHash);

        vm.prank(buyer);
        store.buy{value: price}(id, buyerPubKey, refundWindow);
    }

    function test_DeliveryReceiptHash_CanBeVerifiedOffChain() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        bytes memory ekCiphertext = hex"c001c0de";
        bytes32 buyerPubKeyHash = keccak256(buyerPubKey);

        bytes32 deliveryReceiptHash = keccak256(abi.encode(id, buyer, buyerPubKeyHash, ekCiphertext));

        bytes32 canonicalHash = store.hashDeliveryReceipt(id, buyer, buyerPubKeyHash, ekCiphertext);
        assertEq(canonicalHash, deliveryReceiptHash);

        vm.prank(seller);
        store.deliver(id, buyerPubKey, ekCiphertext);

        assertEq(store.getEkHash(id), keccak256(ekCiphertext));
        assertEq(store.getDeliveryReceiptHash(id), deliveryReceiptHash);
    }

    function test_DeliverTwice_RevertsSecondTime() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        vm.prank(seller);
        store.deliver(id, buyerPubKey, hex"01");

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.deliver(id, buyerPubKey, hex"02");
    }

    function test_RefundAfterDeliver_Reverts() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        vm.prank(seller);
        store.deliver(id, buyerPubKey, hex"01");

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.BadState.selector);
        store.refund(id);
    }

    function test_DeliverMismatchedBuyerPubKey_Reverts() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.BuyerPubKeyMismatch.selector);
        store.deliver(id, hex"0badf00d", hex"beef");
    }

    function test_DeliverEmptyEkCiphertext_Reverts() public {
        uint256 id = _createItemAsSeller();
        _buyAsBuyer(id);

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.EmptyValue.selector);
        store.deliver(id, buyerPubKey, "");
    }
}
