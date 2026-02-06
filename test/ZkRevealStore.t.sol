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
    bytes buyerPubKey = hex"01020304";
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
        store.buy{value: price}(itemId, buyerPubKey, refundWindow);
    }

    // 1) create → buy → reveal (seller gets paid)
    function test_HappyPath_RevealPaysSeller() public {
        uint256 id = _createItemAsSeller();

        uint256 sellerBalBefore = seller.balance;

        _buyAsBuyer(id);

        // Seller reveals EK before deadline => seller paid immediately
        bytes memory ek = hex"deadbeef";

        vm.prank(seller);
        store.revealEk(id, ek);

        assertEq(uint8(store.getState(id)), uint8(ZkRevealStore.State.Revealed));
        assertEq(seller.balance, sellerBalBefore + price);

        // EK stored
        assertEq(store.getEk(id), ek);
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
        store.revealEk(id, hex"01");
    }

    // 5) nonexistent item reverts (ItemNotFound)
    function test_ItemNotFound_RevertsOnBuy() public {
        uint256 fakeId = 999999;

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.buy{value: price}(fakeId, buyerPubKey, refundWindow);
    }

    function test_ItemNotFound_RevertsOnReveal() public {
        uint256 fakeId = 999999;

        vm.prank(seller);
        vm.expectRevert(ZkRevealStore.ItemNotFound.selector);
        store.revealEk(fakeId, hex"01");
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
        store.buy{value: price - 1}(id, buyerPubKey, refundWindow);
    }

    function test_BuyEmptyPubKey_Reverts() public {
        uint256 id = _createItemAsSeller();

        vm.prank(buyer);
        vm.expectRevert(ZkRevealStore.InvalidParams.selector);
        store.buy{value: price}(id, "", refundWindow);
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

        bytes32 expectedHash = keccak256(abi.encodePacked(buyerPubKey));

        vm.expectEmit(true, true, true, true);
        emit ZkRevealStore.ItemBought(id, buyer, price, uint64(block.timestamp) + refundWindow, expectedHash);

        vm.prank(buyer);
        store.buy{value: price}(id, buyerPubKey, refundWindow);
    }
}
