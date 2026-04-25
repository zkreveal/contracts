// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FeeMath} from "./FeeMath.sol";

/// @title RevealReceiptStore
/// @notice Seller-first managed receipt contract for zkReveal Receipt Mode.
/// @dev Sellers create listings, buyers pay with seller-issued purchase references,
/// and settlement completes immediately with an on-chain receipt record.
contract RevealReceiptStore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1_000;

    IERC20 public immutable settlementToken;
    address public immutable feeRecipient;
    uint16 public immutable protocolFeeBps;

    struct Listing {
        address seller;
        string title;
        string resourceId;
        uint256 unitPrice;
        bool active;
    }

    /// @dev Receipt Mode proof-of-payment record. Fulfillment meaning remains off-chain in seller systems.
    struct Receipt {
        bool exists;
        uint256 listingId;
        address seller;
        address buyer;
        uint256 amount;
        bytes32 purchaseRef;
        uint64 issuedAt;
    }

    uint256 public nextListingId = 1;
    uint256 public nextReceiptId = 1;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Receipt) public receipts;
    mapping(address => uint256[]) public listingsBySeller;
    mapping(address => uint256[]) public receiptsByBuyer;
    mapping(address => uint256[]) public receiptsBySeller;
    /// @dev Seller-issued `purchaseRef` values are generated off-chain and enforced as unique per seller.
    mapping(address => mapping(bytes32 => bool)) public purchaseRefUsed;
    /// @dev Deterministic seller-scoped reconciliation helper for off-chain generated refs. Returns 0 if unused.
    mapping(address => mapping(bytes32 => uint256)) public receiptIdBySellerAndPurchaseRef;

    event ListingCreated(
        uint256 indexed listingId, address indexed seller, string title, string resourceId, uint256 unitPrice
    );

    event ListingStatusChanged(uint256 indexed listingId, address indexed seller, bool active);

    event ReceiptPurchased(
        uint256 indexed receiptId,
        uint256 indexed listingId,
        address indexed buyer,
        address seller,
        uint256 amount,
        bytes32 purchaseRef,
        string resourceId
    );

    event ProtocolFeePaid(
        uint256 indexed receiptId, uint256 indexed listingId, address indexed recipient, uint256 amount
    );

    error ListingNotFound();
    error ReceiptNotFound();
    error NotListingSeller();
    error ListingInactive();
    error InvalidParams();
    error PurchaseRefAlreadyUsed();

    modifier listingExists(uint256 listingId) {
        _listingExists(listingId);
        _;
    }

    modifier receiptExists(uint256 receiptId) {
        _receiptExists(receiptId);
        _;
    }

    constructor(address settlementToken_, address feeRecipient_, uint16 protocolFeeBps_) {
        if (settlementToken_ == address(0)) revert InvalidParams();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert InvalidParams();
        if (protocolFeeBps_ > 0 && feeRecipient_ == address(0)) revert InvalidParams();

        settlementToken = IERC20(settlementToken_);
        feeRecipient = feeRecipient_;
        protocolFeeBps = protocolFeeBps_;
    }

    function _quoteProtocolFee(uint256 grossAmount) internal view returns (uint256) {
        return grossAmount * protocolFeeBps / FeeMath.BPS_DENOMINATOR;
    }

    function _listingExists(uint256 listingId) internal view {
        if (listings[listingId].seller == address(0)) revert ListingNotFound();
    }

    function _receiptExists(uint256 receiptId) internal view {
        if (!receipts[receiptId].exists) revert ReceiptNotFound();
    }

    function _onlyListingSeller(uint256 listingId) internal view {
        if (listings[listingId].seller != msg.sender) revert NotListingSeller();
    }

    /// @notice Create a seller-owned listing for Receipt Mode purchases.
    /// @dev `unitPrice` is denominated in settlement token base units.
    ///      `listingId` is the canonical on-chain identifier and `resourceId` is seller-defined semantic metadata.
    function createListing(string calldata title, string calldata resourceId, uint256 unitPrice)
        external
        returns (uint256 listingId)
    {
        if (bytes(title).length == 0) revert InvalidParams();
        if (bytes(resourceId).length == 0) revert InvalidParams();
        if (unitPrice == 0) revert InvalidParams();

        listingId = nextListingId++;

        Listing storage listing = listings[listingId];
        listing.seller = msg.sender;
        listing.title = title;
        listing.resourceId = resourceId;
        listing.unitPrice = unitPrice;
        listing.active = true;

        listingsBySeller[msg.sender].push(listingId);

        emit ListingCreated(listingId, msg.sender, title, resourceId, unitPrice);
    }

    /// @notice Update the active status of a seller-owned listing.
    function setListingActive(uint256 listingId, bool active) external listingExists(listingId) {
        _onlyListingSeller(listingId);
        listings[listingId].active = active;
        emit ListingStatusChanged(listingId, msg.sender, active);
    }

    /// @notice Purchase a Receipt Mode listing using a seller-issued off-chain purchase reference.
    /// @dev `purchaseRef` is a seller-issued off-chain purchase intent reference and must be unique per seller.
    ///      No on-chain pre-registration happens, no escrow is created, payment settles immediately,
    ///      and fulfillment remains entirely off-chain in the seller's own backend or dashboard.
    function purchaseReceipt(uint256 listingId, bytes32 purchaseRef)
        external
        nonReentrant
        listingExists(listingId)
        returns (uint256 receiptId)
    {
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingInactive();
        if (purchaseRef == bytes32(0)) revert InvalidParams();
        if (purchaseRefUsed[listing.seller][purchaseRef]) revert PurchaseRefAlreadyUsed();

        settlementToken.safeTransferFrom(msg.sender, address(this), listing.unitPrice);

        purchaseRefUsed[listing.seller][purchaseRef] = true;

        receiptId = nextReceiptId++;

        Receipt storage receipt = receipts[receiptId];
        receipt.exists = true;
        receipt.listingId = listingId;
        receipt.seller = listing.seller;
        receipt.buyer = msg.sender;
        receipt.amount = listing.unitPrice;
        receipt.purchaseRef = purchaseRef;
        receipt.issuedAt = uint64(block.timestamp);

        receiptsByBuyer[msg.sender].push(receiptId);
        receiptsBySeller[listing.seller].push(receiptId);
        receiptIdBySellerAndPurchaseRef[listing.seller][purchaseRef] = receiptId;

        uint256 protocolFee = _quoteProtocolFee(listing.unitPrice);

        if (protocolFee > 0) {
            settlementToken.safeTransfer(feeRecipient, protocolFee);
            emit ProtocolFeePaid(receiptId, listingId, feeRecipient, protocolFee);
        }

        settlementToken.safeTransfer(listing.seller, listing.unitPrice - protocolFee);

        emit ReceiptPurchased(
            receiptId, listingId, msg.sender, listing.seller, listing.unitPrice, purchaseRef, listing.resourceId
        );
    }

    /// @notice Quote gross amount, protocol fee, seller net, and fee recipient for a receipt purchase.
    function quotePurchaseReceipt(uint256 listingId)
        external
        view
        listingExists(listingId)
        returns (uint256 grossAmount, uint256 protocolFee, uint256 sellerNet, address quotedFeeRecipient)
    {
        Listing storage listing = listings[listingId];
        grossAmount = listing.unitPrice;
        protocolFee = _quoteProtocolFee(grossAmount);
        quotedFeeRecipient = feeRecipient;
        sellerNet = grossAmount - protocolFee;
    }

    function getListingsBySeller(address seller) external view returns (uint256[] memory) {
        return listingsBySeller[seller];
    }

    function getReceiptsByBuyer(address buyer) external view returns (uint256[] memory) {
        return receiptsByBuyer[buyer];
    }

    function getReceiptsBySeller(address seller) external view returns (uint256[] memory) {
        return receiptsBySeller[seller];
    }

    function getListing(uint256 listingId) external view listingExists(listingId) returns (Listing memory) {
        return listings[listingId];
    }

    function getReceipt(uint256 receiptId) external view receiptExists(receiptId) returns (Receipt memory) {
        return receipts[receiptId];
    }

    function getReceiptIdBySellerAndPurchaseRef(address seller, bytes32 purchaseRef) external view returns (uint256) {
        return receiptIdBySellerAndPurchaseRef[seller][purchaseRef];
    }
}
