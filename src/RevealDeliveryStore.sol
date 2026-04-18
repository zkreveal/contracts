// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RevealDeliveryStore
/// @notice Inventory-based encrypted delivery purchases for trusted-seller v0.
/// @dev Sellers create listings, add inventory units, buyers purchase delivery for listing units, and settlement remains escrow-based internally.
contract RevealDeliveryStore is ReentrancyGuard {
    uint64 public constant MIN_REFUND_WINDOW = 5 minutes;
    uint64 public constant MAX_REFUND_WINDOW = 30 days;

    enum EscrowStatus {
        Pending,
        Delivered,
        Reclaimed
    }

    struct Listing {
        address seller;
        string title;
        string resourceId;
        uint256 unitPrice;
        uint64 refundWindow;
        bool active;
        uint256 nextInventoryUnitIndex;
        uint256 totalInventoryUnits;
        uint256 soldInventoryUnits;
    }

    struct InventoryUnit {
        uint256 listingId;
        string contentCID;
        bool consumed;
    }

    struct Escrow {
        bool exists;
        uint256 listingId;
        uint256 inventoryUnitId;
        address seller;
        address buyer;
        uint256 amount;
        bytes buyerPubKey;
        bytes encryptedKey;
        uint64 createdAt;
        uint64 deadline;
        EscrowStatus status;
    }

    uint256 public nextListingId = 1;
    uint256 public nextInventoryUnitId = 1;
    uint256 public nextEscrowId = 1;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => InventoryUnit) public inventoryUnits;
    mapping(uint256 => Escrow) public escrows;

    mapping(address => uint256[]) public listingsBySeller;
    mapping(uint256 => uint256[]) public listingInventoryUnitIds;

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        string title,
        string resourceId,
        uint256 unitPrice,
        uint64 refundWindow
    );

    event InventoryUnitAdded(uint256 indexed listingId, uint256 count);

    event ListingStatusChanged(uint256 indexed listingId, bool active);

    /// @dev `listingId` is the canonical on-chain identity; `resourceId` is seller-defined semantic metadata.
    event EscrowCreated(
        uint256 indexed escrowId,
        uint256 indexed listingId,
        uint256 indexed inventoryUnitId,
        address seller,
        address buyer,
        uint256 amount,
        string resourceId
    );

    /// @dev Emits canonical escrow/listing identifiers plus non-canonical `resourceId` metadata for off-chain consumers.
    event EscrowDelivered(
        uint256 indexed escrowId, uint256 indexed listingId, address indexed buyer, string resourceId, string contentCID
    );

    /// @dev Emits canonical escrow/listing identifiers plus non-canonical `resourceId` metadata for off-chain consumers.
    event EscrowReclaimed(
        uint256 indexed escrowId, uint256 indexed listingId, address indexed buyer, string resourceId
    );

    error ListingNotFound();
    error InventoryUnitNotFound();
    error EscrowNotFound();
    error NotListingSeller();
    error NotEscrowSeller();
    error NotEscrowBuyer();
    error ListingInactive();
    error SoldOut();
    error BadState();
    error BadPrice();
    error InvalidParams();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error EmptyValue();
    error PayFail();
    error RefundFail();

    modifier listingExists(uint256 listingId) {
        _listingExists(listingId);
        _;
    }

    modifier escrowExists(uint256 escrowId) {
        _escrowExists(escrowId);
        _;
    }

    modifier inventoryUnitExists(uint256 inventoryUnitId) {
        _inventoryUnitExists(inventoryUnitId);
        _;
    }

    function _listingExists(uint256 listingId) internal view {
        if (listings[listingId].seller == address(0)) revert ListingNotFound();
    }

    function _escrowExists(uint256 escrowId) internal view {
        if (!escrows[escrowId].exists) revert EscrowNotFound();
    }

    function _inventoryUnitExists(uint256 inventoryUnitId) internal view {
        if (inventoryUnits[inventoryUnitId].listingId == 0) revert InventoryUnitNotFound();
    }

    function _onlyListingSeller(uint256 listingId) internal view {
        if (listings[listingId].seller != msg.sender) revert NotListingSeller();
    }

    function _onlyEscrowSeller(uint256 escrowId) internal view {
        if (escrows[escrowId].seller != msg.sender) revert NotEscrowSeller();
    }

    function _onlyEscrowBuyer(uint256 escrowId) internal view {
        if (escrows[escrowId].buyer != msg.sender) revert NotEscrowBuyer();
    }

    /// @notice Create a seller-owned listing with a human-readable title and seller-defined semantic resource identifier.
    /// @dev `listingId` remains the canonical on-chain identifier; `resourceId` is a non-unique, non-normalized off-chain hint.
    function createListing(string calldata title, string calldata resourceId, uint256 unitPrice, uint64 refundWindow)
        external
        returns (uint256 listingId)
    {
        if (bytes(title).length == 0) revert InvalidParams();
        if (bytes(resourceId).length == 0) revert InvalidParams();
        if (unitPrice == 0) revert InvalidParams();
        if (refundWindow < MIN_REFUND_WINDOW || refundWindow > MAX_REFUND_WINDOW) revert InvalidParams();

        listingId = nextListingId++;

        Listing storage listing = listings[listingId];
        listing.seller = msg.sender;
        listing.title = title;
        listing.resourceId = resourceId;
        listing.unitPrice = unitPrice;
        listing.refundWindow = refundWindow;
        listing.active = true;
        listing.nextInventoryUnitIndex = 0;
        listing.totalInventoryUnits = 0;
        listing.soldInventoryUnits = 0;

        listingsBySeller[msg.sender].push(listingId);

        emit ListingCreated(listingId, msg.sender, title, resourceId, unitPrice, refundWindow);
    }

    function addInventoryUnitsToListing(uint256 listingId, uint256 count) external listingExists(listingId) {
        _onlyListingSeller(listingId);
        if (count == 0) revert InvalidParams();

        Listing storage listing = listings[listingId];

        for (uint256 i = 0; i < count; i++) {
            uint256 inventoryUnitId = nextInventoryUnitId++;

            InventoryUnit storage inventoryUnit = inventoryUnits[inventoryUnitId];
            inventoryUnit.listingId = listingId;
            inventoryUnit.consumed = false;

            listingInventoryUnitIds[listingId].push(inventoryUnitId);
            listing.totalInventoryUnits += 1;
        }

        emit InventoryUnitAdded(listingId, count);
    }

    function setListingActive(uint256 listingId, bool active) external listingExists(listingId) {
        _onlyListingSeller(listingId);
        listings[listingId].active = active;
        emit ListingStatusChanged(listingId, active);
    }

    function _allocateNextInventoryUnit(uint256 listingId) internal returns (uint256 inventoryUnitId) {
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingInactive();

        uint256[] storage inventoryUnitIdList = listingInventoryUnitIds[listingId];
        if (listing.nextInventoryUnitIndex >= inventoryUnitIdList.length) revert SoldOut();

        inventoryUnitId = inventoryUnitIdList[listing.nextInventoryUnitIndex];
        listing.nextInventoryUnitIndex += 1;

        InventoryUnit storage inventoryUnit = inventoryUnits[inventoryUnitId];
        if (inventoryUnit.listingId != listingId) revert BadState();
        if (inventoryUnit.consumed) revert BadState();

        inventoryUnit.consumed = true;
        listing.soldInventoryUnits += 1;
    }

    /// @notice Purchase one listing unit through delivery mode using a buyer encryption public key.
    /// @dev Internally this allocates inventory and creates escrow state for delivery and refund handling.
    function purchaseDelivery(uint256 listingId, bytes calldata buyerPubKey)
        external
        payable
        listingExists(listingId)
        returns (uint256 escrowId)
    {
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingInactive();
        if (buyerPubKey.length == 0) revert InvalidParams();
        if (msg.value != listing.unitPrice) revert BadPrice();

        uint256 inventoryUnitId = _allocateNextInventoryUnit(listingId);

        escrowId = nextEscrowId++;

        Escrow storage escrow = escrows[escrowId];
        escrow.exists = true;
        escrow.listingId = listingId;
        escrow.inventoryUnitId = inventoryUnitId;
        escrow.seller = listing.seller;
        escrow.buyer = msg.sender;
        escrow.amount = listing.unitPrice;
        escrow.buyerPubKey = buyerPubKey;
        escrow.encryptedKey = "";
        escrow.createdAt = uint64(block.timestamp);
        escrow.deadline = escrow.createdAt + listing.refundWindow;
        escrow.status = EscrowStatus.Pending;

        emit EscrowCreated(
            escrowId, listingId, inventoryUnitId, listing.seller, msg.sender, listing.unitPrice, listing.resourceId
        );
    }

    /// @notice Seller posts a content CID and encrypted delivery payload, then receives escrowed funds.
    /// @dev v0 only checks that both values are non-empty and submitted on or before the deadline.
    ///      Payload correctness and buyer-side decryptability are verified off-chain.
    function deliverEscrow(uint256 escrowId, string calldata contentCID, bytes calldata encryptedKey)
        external
        escrowExists(escrowId)
        nonReentrant
    {
        _onlyEscrowSeller(escrowId);

        Escrow storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Pending) revert BadState();
        if (bytes(contentCID).length == 0) revert EmptyValue();
        if (encryptedKey.length == 0) revert EmptyValue();
        if (block.timestamp > escrow.deadline) revert DeadlinePassed();

        InventoryUnit storage inventoryUnit = inventoryUnits[escrow.inventoryUnitId];
        if (inventoryUnit.listingId != escrow.listingId) revert BadState();
        if (bytes(inventoryUnit.contentCID).length != 0) revert BadState();

        inventoryUnit.contentCID = contentCID;
        escrow.encryptedKey = encryptedKey;
        escrow.status = EscrowStatus.Delivered;
        Listing storage listing = listings[escrow.listingId];
        string memory listingResourceId = listing.resourceId;

        (bool ok,) = escrow.seller.call{value: escrow.amount}("");
        if (!ok) revert PayFail();

        emit EscrowDelivered(escrowId, escrow.listingId, escrow.buyer, listingResourceId, contentCID);
    }

    function reclaimEscrow(uint256 escrowId) external escrowExists(escrowId) nonReentrant {
        _onlyEscrowBuyer(escrowId);

        Escrow storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Pending) revert BadState();
        if (block.timestamp <= escrow.deadline) revert DeadlineNotPassed();

        escrow.status = EscrowStatus.Reclaimed;
        Listing storage listing = listings[escrow.listingId];
        string memory listingResourceId = listing.resourceId;

        (bool ok,) = escrow.buyer.call{value: escrow.amount}("");
        if (!ok) revert RefundFail();

        emit EscrowReclaimed(escrowId, escrow.listingId, escrow.buyer, listingResourceId);
    }

    function getListingsBySeller(address seller) external view returns (uint256[] memory) {
        return listingsBySeller[seller];
    }

    function getListingInventoryUnitIds(uint256 listingId)
        external
        view
        listingExists(listingId)
        returns (uint256[] memory)
    {
        return listingInventoryUnitIds[listingId];
    }

    function getListingRemainingInventoryUnits(uint256 listingId)
        public
        view
        listingExists(listingId)
        returns (uint256)
    {
        Listing storage listing = listings[listingId];
        return listing.totalInventoryUnits - listing.soldInventoryUnits;
    }

    function isListingSoldOut(uint256 listingId) public view listingExists(listingId) returns (bool) {
        return getListingRemainingInventoryUnits(listingId) == 0;
    }

    function getListingInventorySummary(uint256 listingId)
        external
        view
        listingExists(listingId)
        returns (uint256 totalInventoryUnits, uint256 soldInventoryUnits, uint256 remainingInventoryUnits, bool soldOut)
    {
        Listing storage listing = listings[listingId];
        totalInventoryUnits = listing.totalInventoryUnits;
        soldInventoryUnits = listing.soldInventoryUnits;
        remainingInventoryUnits = listing.totalInventoryUnits - listing.soldInventoryUnits;
        soldOut = remainingInventoryUnits == 0;
    }

    function getListing(uint256 listingId) external view listingExists(listingId) returns (Listing memory) {
        return listings[listingId];
    }

    function getInventoryUnit(uint256 inventoryUnitId)
        external
        view
        inventoryUnitExists(inventoryUnitId)
        returns (InventoryUnit memory)
    {
        return inventoryUnits[inventoryUnitId];
    }

    function getEscrow(uint256 escrowId) external view escrowExists(escrowId) returns (Escrow memory) {
        return escrows[escrowId];
    }
}
