// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {RevealReceiptStore} from "../src/RevealReceiptStore.sol";

contract ReceiptMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RevealReceiptStoreTest is Test {
    ReceiptMockUSDC usdc;
    RevealReceiptStore store;

    address seller = address(0xA11CE);
    address seller2 = address(0xABCD);
    address buyer = address(0xB0B);
    address buyer2 = address(0xCAFE);
    address attacker = address(0xD00D);
    address feeRecipient = address(0xFEE);

    string title = "Pro Dataset";
    string resourceId = "dataset/btc-signals-mar-2026";
    uint256 unitPrice = 100_000_000;
    bytes32 purchaseRef = keccak256("purchase-1");
    bytes32 purchaseRef2 = keccak256("purchase-2");

    function setUp() public {
        usdc = new ReceiptMockUSDC();
        store = new RevealReceiptStore(address(usdc), feeRecipient, 0);

        usdc.mint(buyer, 1_000_000_000);
        usdc.mint(buyer2, 1_000_000_000);
        usdc.mint(attacker, 1_000_000_000);

        vm.deal(seller, 10 ether);
        vm.deal(seller2, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(buyer2, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _deployStore(uint16 feeBps) internal returns (RevealReceiptStore deployedStore) {
        deployedStore = new RevealReceiptStore(address(usdc), feeRecipient, feeBps);
    }

    function _createListingAs(address sellerAccount, string memory listingTitle, string memory listingResourceId)
        internal
        returns (uint256 listingId)
    {
        vm.prank(sellerAccount);
        listingId = store.createListing(listingTitle, listingResourceId, unitPrice);
    }

    function _createListingAs(
        RevealReceiptStore targetStore,
        address sellerAccount,
        string memory listingTitle,
        string memory listingResourceId
    ) internal returns (uint256 listingId) {
        vm.prank(sellerAccount);
        listingId = targetStore.createListing(listingTitle, listingResourceId, unitPrice);
    }

    function _createListingAsSeller() internal returns (uint256 listingId) {
        listingId = _createListingAs(seller, title, resourceId);
    }

    function _purchaseReceiptAs(RevealReceiptStore targetStore, uint256 listingId, address who, bytes32 ref)
        internal
        returns (uint256 receiptId)
    {
        vm.startPrank(who);
        usdc.approve(address(targetStore), unitPrice);
        receiptId = targetStore.purchaseReceipt(listingId, ref);
        vm.stopPrank();
    }

    function _purchaseReceiptAs(uint256 listingId, address who, bytes32 ref) internal returns (uint256 receiptId) {
        receiptId = _purchaseReceiptAs(store, listingId, who, ref);
    }

    function test_ListingCreated_Emits() public {
        vm.expectEmit(true, true, false, true);
        emit RevealReceiptStore.ListingCreated(1, seller, title, resourceId, unitPrice);

        vm.prank(seller);
        store.createListing(title, resourceId, unitPrice);
    }

    function test_CreateListing_SetsFields() public {
        uint256 listingId = _createListingAsSeller();

        RevealReceiptStore.Listing memory listing = store.getListing(listingId);
        assertEq(listing.seller, seller);
        assertEq(listing.title, title);
        assertEq(listing.resourceId, resourceId);
        assertEq(listing.unitPrice, unitPrice);
        assertEq(listing.active, true);

        (
            address listingSeller,
            string memory listingTitle,
            string memory listingResourceId,
            uint256 listingUnitPrice,
            bool listingActive
        ) = store.listings(listingId);
        assertEq(listingSeller, seller);
        assertEq(listingTitle, title);
        assertEq(listingResourceId, resourceId);
        assertEq(listingUnitPrice, unitPrice);
        assertEq(listingActive, true);

        uint256[] memory listingIds = store.getListingsBySeller(seller);
        assertEq(listingIds.length, 1);
        assertEq(listingIds[0], listingId);
    }

    function test_CreateListing_InvalidParamsRevert() public {
        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.createListing("", resourceId, unitPrice);

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.createListing(title, "", unitPrice);

        vm.prank(seller);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.createListing(title, resourceId, 0);
    }

    function test_Constructor_InvalidParamsRevert() public {
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(0), feeRecipient, 0);

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(usdc), address(0), 1);

        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        new RevealReceiptStore(address(usdc), feeRecipient, 1_001);
    }

    function test_Constructor_AllowsZeroFeeRecipientWhenFeeDisabled() public {
        RevealReceiptStore zeroFeeStore = new RevealReceiptStore(address(usdc), address(0), 0);

        assertEq(address(zeroFeeStore.settlementToken()), address(usdc));
        assertEq(zeroFeeStore.feeRecipient(), address(0));
        assertEq(zeroFeeStore.protocolFeeBps(), 0);
    }

    function test_SetListingActive_TogglesAndBlocksPurchases() public {
        uint256 listingId = _createListingAsSeller();

        vm.expectEmit(true, true, false, true);
        emit RevealReceiptStore.ListingStatusChanged(listingId, seller, false);

        vm.prank(seller);
        store.setListingActive(listingId, false);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.ListingInactive.selector);
        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        vm.prank(seller);
        store.setListingActive(listingId, true);

        uint256 receiptId = _purchaseReceiptAs(listingId, buyer, purchaseRef);
        assertEq(receiptId, 1);
    }

    function test_SetListingActive_NonSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.prank(attacker);
        vm.expectRevert(RevealReceiptStore.NotListingSeller.selector);
        store.setListingActive(listingId, false);
    }

    function test_PurchaseReceipt_SettlesImmediatelyAndStoresReceipt() public {
        uint256 listingId = _createListingAsSeller();
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), 0);

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, listingId, buyer, seller, unitPrice, purchaseRef, resourceId);

        uint256 receiptId = store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        assertEq(receiptId, 1);

        RevealReceiptStore.Receipt memory receipt = store.getReceipt(receiptId);
        assertEq(receipt.exists, true);
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.seller, seller);
        assertEq(receipt.buyer, buyer);
        assertEq(receipt.amount, unitPrice);
        assertEq(receipt.purchaseRef, purchaseRef);
        assertEq(receipt.issuedAt, block.timestamp);

        uint256[] memory buyerReceiptIds = store.getReceiptsByBuyer(buyer);
        assertEq(buyerReceiptIds.length, 1);
        assertEq(buyerReceiptIds[0], receiptId);

        uint256[] memory sellerReceiptIds = store.getReceiptsBySeller(seller);
        assertEq(sellerReceiptIds.length, 1);
        assertEq(sellerReceiptIds[0], receiptId);

        assertEq(store.purchaseRefUsed(seller, purchaseRef), true);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - unitPrice);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + unitPrice);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore);
        assertEq(usdc.balanceOf(address(store)), 0);
    }

    function test_PurchaseReceipt_PaysProtocolFeeAndSellerNet() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, title, resourceId);
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 protocolFee = unitPrice * 500 / 10_000;

        vm.startPrank(buyer);
        usdc.approve(address(feeStore), unitPrice);

        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ProtocolFeePaid(1, listingId, feeRecipient, protocolFee);
        vm.expectEmit(true, true, true, true);
        emit RevealReceiptStore.ReceiptPurchased(1, listingId, buyer, seller, unitPrice, purchaseRef, resourceId);

        feeStore.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + protocolFee);
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + (unitPrice - protocolFee));
        assertEq(usdc.balanceOf(address(feeStore)), 0);
    }

    function test_PurchaseReceipt_ZeroPurchaseRefReverts() public {
        uint256 listingId = _createListingAsSeller();

        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.InvalidParams.selector);
        store.purchaseReceipt(listingId, bytes32(0));
        vm.stopPrank();
    }

    function test_PurchaseReceipt_DuplicatePurchaseRefSameSellerReverts() public {
        uint256 listingId = _createListingAsSeller();

        _purchaseReceiptAs(listingId, buyer, purchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_PurchaseRefUniquePerSellerAcrossListings() public {
        uint256 listingId1 = _createListingAs(seller, title, resourceId);
        uint256 listingId2 = _createListingAs(seller, "Pro Feed", "feed/eth-signals");

        _purchaseReceiptAs(listingId1, buyer, purchaseRef);

        vm.startPrank(buyer2);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.PurchaseRefAlreadyUsed.selector);
        store.purchaseReceipt(listingId2, purchaseRef);
        vm.stopPrank();
    }

    function test_PurchaseReceipt_AllowsSamePurchaseRefAcrossDifferentSellers() public {
        uint256 listingId1 = _createListingAs(seller, title, resourceId);
        uint256 listingId2 = _createListingAs(seller2, "Seller Two", "dataset/eth-signals-apr-2026");

        uint256 receiptId1 = _purchaseReceiptAs(listingId1, buyer, purchaseRef);
        uint256 receiptId2 = _purchaseReceiptAs(listingId2, buyer2, purchaseRef);

        assertEq(receiptId1, 1);
        assertEq(receiptId2, 2);
        assertEq(store.purchaseRefUsed(seller, purchaseRef), true);
        assertEq(store.purchaseRefUsed(seller2, purchaseRef), true);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller, purchaseRef), receiptId1);
        assertEq(store.getReceiptIdBySellerAndPurchaseRef(seller2, purchaseRef), receiptId2);
    }

    function test_PurchaseReceipt_NonexistentListingReverts() public {
        vm.startPrank(buyer);
        usdc.approve(address(store), unitPrice);
        vm.expectRevert(RevealReceiptStore.ListingNotFound.selector);
        store.purchaseReceipt(999, purchaseRef);
        vm.stopPrank();
    }

    function test_QuotePurchaseReceipt_ReturnsGrossFeeAndNet() public {
        RevealReceiptStore feeStore = _deployStore(500);
        uint256 listingId = _createListingAs(feeStore, seller, title, resourceId);

        (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient) =
            feeStore.quotePurchaseReceipt(listingId);

        assertEq(grossAmount, unitPrice);
        assertEq(protocolFee, unitPrice * 500 / 10_000);
        assertEq(sellerNet, unitPrice - protocolFee);
        assertEq(quotedFeeRecipient, feeRecipient);
    }

    function test_GetListingAndReceipt_NotFoundRevert() public {
        vm.expectRevert(RevealReceiptStore.ListingNotFound.selector);
        store.getListing(999);

        vm.expectRevert(RevealReceiptStore.ReceiptNotFound.selector);
        store.getReceipt(999);
    }

    function test_GetReceiptsByBuyerAndSeller_TracksMultipleReceipts() public {
        uint256 listingId1 = _createListingAsSeller();
        uint256 listingId2 = _createListingAs(seller, "Pro Feed", "feed/eth-signals");

        uint256 receiptId1 = _purchaseReceiptAs(listingId1, buyer, purchaseRef);
        uint256 receiptId2 = _purchaseReceiptAs(listingId2, buyer, purchaseRef2);

        uint256[] memory buyerReceiptIds = store.getReceiptsByBuyer(buyer);
        assertEq(buyerReceiptIds.length, 2);
        assertEq(buyerReceiptIds[0], receiptId1);
        assertEq(buyerReceiptIds[1], receiptId2);

        uint256[] memory sellerReceiptIds = store.getReceiptsBySeller(seller);
        assertEq(sellerReceiptIds.length, 2);
        assertEq(sellerReceiptIds[0], receiptId1);
        assertEq(sellerReceiptIds[1], receiptId2);
    }
}
