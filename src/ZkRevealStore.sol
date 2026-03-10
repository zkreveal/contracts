// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ZkRevealStore
/// @notice Inventory-based encrypted delivery escrow.
/// @dev Sellers create products, add per-unit inventory items, buyers create escrows for product units, and settlement is escrow-based.
contract ZkRevealStore is ReentrancyGuard {
    uint64 public constant MIN_REFUND_WINDOW = 5 minutes;
    uint64 public constant MAX_REFUND_WINDOW = 30 days;

    enum EscrowStatus {
        Pending,
        Delivered,
        Reclaimed
    }

    struct Product {
        address seller;
        string title;
        uint256 unitPrice;
        uint64 refundWindow;
        bool active;
        uint256 nextItemIndex;
        uint256 totalItems;
        uint256 soldItems;
    }

    struct ProductItem {
        uint256 productId;
        string contentCID;
        bool consumed;
    }

    struct Escrow {
        bool exists;
        uint256 productId;
        uint256 itemId;
        address seller;
        address buyer;
        uint256 amount;
        bytes buyerPubKey;
        bytes encryptedKey;
        uint64 createdAt;
        uint64 deadline;
        EscrowStatus status;
    }

    uint256 public nextProductId = 1;
    uint256 public nextItemId = 1;
    uint256 public nextEscrowId = 1;

    mapping(uint256 => Product) public products;
    mapping(uint256 => ProductItem) public productItems;
    mapping(uint256 => Escrow) public escrows;

    mapping(address => uint256[]) public productsBySeller;
    mapping(uint256 => uint256[]) public productItemIds;

    event ProductCreated(
        uint256 indexed productId, address indexed seller, string title, uint256 unitPrice, uint64 refundWindow
    );

    event ProductItemsAdded(uint256 indexed productId, uint256 count);

    event ProductStatusChanged(uint256 indexed productId, bool active);

    event EscrowCreated(
        uint256 indexed escrowId,
        uint256 indexed productId,
        uint256 indexed itemId,
        address seller,
        address buyer,
        uint256 amount
    );

    event EscrowDelivered(uint256 indexed escrowId);

    event EscrowReclaimed(uint256 indexed escrowId);

    error ProductNotFound();
    error ItemNotFound();
    error EscrowNotFound();
    error NotProductSeller();
    error NotEscrowSeller();
    error NotEscrowBuyer();
    error ProductInactive();
    error SoldOut();
    error BadState();
    error BadPrice();
    error InvalidParams();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error EmptyValue();
    error PayFail();
    error RefundFail();

    modifier productExists(uint256 productId) {
        _productExists(productId);
        _;
    }

    modifier escrowExists(uint256 escrowId) {
        _escrowExists(escrowId);
        _;
    }

    modifier itemExists(uint256 itemId) {
        _itemExists(itemId);
        _;
    }

    function _productExists(uint256 productId) internal view {
        if (products[productId].seller == address(0)) revert ProductNotFound();
    }

    function _escrowExists(uint256 escrowId) internal view {
        if (!escrows[escrowId].exists) revert EscrowNotFound();
    }

    function _itemExists(uint256 itemId) internal view {
        if (productItems[itemId].productId == 0) revert ItemNotFound();
    }

    function _onlyProductSeller(uint256 productId) internal view {
        if (products[productId].seller != msg.sender) revert NotProductSeller();
    }

    function _onlyEscrowSeller(uint256 escrowId) internal view {
        if (escrows[escrowId].seller != msg.sender) revert NotEscrowSeller();
    }

    function _onlyEscrowBuyer(uint256 escrowId) internal view {
        if (escrows[escrowId].buyer != msg.sender) revert NotEscrowBuyer();
    }

    function createProduct(string calldata title, uint256 unitPrice, uint64 refundWindow)
        external
        returns (uint256 productId)
    {
        if (bytes(title).length == 0) revert InvalidParams();
        if (unitPrice == 0) revert InvalidParams();
        if (refundWindow < MIN_REFUND_WINDOW || refundWindow > MAX_REFUND_WINDOW) revert InvalidParams();

        productId = nextProductId++;

        Product storage product = products[productId];
        product.seller = msg.sender;
        product.title = title;
        product.unitPrice = unitPrice;
        product.refundWindow = refundWindow;
        product.active = true;
        product.nextItemIndex = 0;
        product.totalItems = 0;
        product.soldItems = 0;

        productsBySeller[msg.sender].push(productId);

        emit ProductCreated(productId, msg.sender, title, unitPrice, refundWindow);
    }

    function addItemsToProduct(uint256 productId, string[] calldata contentCIDs) external productExists(productId) {
        _onlyProductSeller(productId);
        if (contentCIDs.length == 0) revert InvalidParams();

        Product storage product = products[productId];

        for (uint256 i = 0; i < contentCIDs.length; i++) {
            string calldata cid = contentCIDs[i];
            if (bytes(cid).length == 0) revert InvalidParams();

            uint256 itemId = nextItemId++;

            ProductItem storage productItem = productItems[itemId];
            productItem.productId = productId;
            productItem.contentCID = cid;
            productItem.consumed = false;

            productItemIds[productId].push(itemId);
            product.totalItems += 1;
        }

        emit ProductItemsAdded(productId, contentCIDs.length);
    }

    function setProductActive(uint256 productId, bool active) external productExists(productId) {
        _onlyProductSeller(productId);
        products[productId].active = active;
        emit ProductStatusChanged(productId, active);
    }

    function _allocateNextProductItem(uint256 productId) internal returns (uint256 itemId) {
        Product storage product = products[productId];

        if (!product.active) revert ProductInactive();

        uint256[] storage productItemIdList = productItemIds[productId];
        if (product.nextItemIndex >= productItemIdList.length) revert SoldOut();

        itemId = productItemIdList[product.nextItemIndex];
        product.nextItemIndex += 1;

        ProductItem storage productItem = productItems[itemId];
        if (productItem.productId != productId) revert BadState();
        if (productItem.consumed) revert BadState();

        productItem.consumed = true;
        product.soldItems += 1;
    }

    function createEscrow(uint256 productId, bytes calldata buyerPubKey)
        external
        payable
        productExists(productId)
        returns (uint256 escrowId)
    {
        Product storage product = products[productId];

        if (!product.active) revert ProductInactive();
        if (buyerPubKey.length == 0) revert InvalidParams();
        if (msg.value != product.unitPrice) revert BadPrice();

        uint256 itemId = _allocateNextProductItem(productId);

        escrowId = nextEscrowId++;

        Escrow storage escrow = escrows[escrowId];
        escrow.exists = true;
        escrow.productId = productId;
        escrow.itemId = itemId;
        escrow.seller = product.seller;
        escrow.buyer = msg.sender;
        escrow.amount = product.unitPrice;
        escrow.buyerPubKey = buyerPubKey;
        escrow.encryptedKey = "";
        escrow.createdAt = uint64(block.timestamp);
        escrow.deadline = escrow.createdAt + product.refundWindow;
        escrow.status = EscrowStatus.Pending;

        emit EscrowCreated(escrowId, productId, itemId, product.seller, msg.sender, product.unitPrice);
    }

    function deliverEscrow(uint256 escrowId, bytes calldata encryptedKey) external escrowExists(escrowId) nonReentrant {
        _onlyEscrowSeller(escrowId);

        Escrow storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Pending) revert BadState();
        if (encryptedKey.length == 0) revert EmptyValue();
        if (block.timestamp > escrow.deadline) revert DeadlinePassed();

        escrow.encryptedKey = encryptedKey;
        escrow.status = EscrowStatus.Delivered;

        (bool ok,) = escrow.seller.call{value: escrow.amount}("");
        if (!ok) revert PayFail();

        emit EscrowDelivered(escrowId);
    }

    function reclaimEscrow(uint256 escrowId) external escrowExists(escrowId) nonReentrant {
        _onlyEscrowBuyer(escrowId);

        Escrow storage escrow = escrows[escrowId];
        if (escrow.status != EscrowStatus.Pending) revert BadState();
        if (block.timestamp <= escrow.deadline) revert DeadlineNotPassed();

        escrow.status = EscrowStatus.Reclaimed;

        (bool ok,) = escrow.buyer.call{value: escrow.amount}("");
        if (!ok) revert RefundFail();

        emit EscrowReclaimed(escrowId);
    }

    function getProductsBySeller(address seller) external view returns (uint256[] memory) {
        return productsBySeller[seller];
    }

    function getProductItemIds(uint256 productId) external view productExists(productId) returns (uint256[] memory) {
        return productItemIds[productId];
    }

    function getProductRemainingItems(uint256 productId) public view productExists(productId) returns (uint256) {
        Product storage product = products[productId];
        return product.totalItems - product.soldItems;
    }

    function isProductSoldOut(uint256 productId) public view productExists(productId) returns (bool) {
        return getProductRemainingItems(productId) == 0;
    }

    function getProductInventorySummary(uint256 productId)
        external
        view
        productExists(productId)
        returns (uint256 totalItems, uint256 soldItems, uint256 remainingItems, bool soldOut)
    {
        Product storage product = products[productId];
        totalItems = product.totalItems;
        soldItems = product.soldItems;
        remainingItems = product.totalItems - product.soldItems;
        soldOut = remainingItems == 0;
    }

    function getProduct(uint256 productId) external view productExists(productId) returns (Product memory) {
        return products[productId];
    }

    function getProductItem(uint256 itemId) external view itemExists(itemId) returns (ProductItem memory) {
        return productItems[itemId];
    }

    function getEscrow(uint256 escrowId) external view escrowExists(escrowId) returns (Escrow memory) {
        return escrows[escrowId];
    }
}
