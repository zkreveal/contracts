// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ZkRevealStore (Privacy-Preserving Delivery Escrow)
/// @notice Seller publishes encrypted-data commitments on-chain, buyer pays, and seller is paid
///         only after posting actual EK ciphertext on-chain before deadline.
/// @dev This improves trust-minimization vs hash-only delivery, while still not proving EK correctness.
contract ZkRevealStore is ReentrancyGuard {
    uint64 public constant MIN_REFUND_WINDOW = 5 minutes;
    uint64 public constant MAX_REFUND_WINDOW = 30 days;

    enum State {
        Listed,
        Paid, // buyer paid, waiting for seller EK
        Committed, // EK ciphertext posted, seller paid
        Refunded,
        Cancelled
    }

    struct Item {
        bool exists;

        address seller;
        address buyer;

        uint256 priceWei;
        string encUriPointer; // pointer/CID to encrypted URI blob
        bytes32 encUriPointerHash; // commitment to encUriPointer bytes
        bytes32 ciphertextHash; // commitment to encrypted content bytes or CID bytes
        bytes32 kHash; // mandatory commitment keccak256(K || salt)

        bytes32 buyerPubKeyHash; // keccak256(buyerPubKey) captured at buy()
        uint64 deadline; // refund deadline (unix time)
        State state;

        bytes32 ekHash; // keccak256(ekCiphertext)
        bytes32 deliveryReceiptHash; // keccak256(abi.encode(itemId, buyer, buyerPubKeyHash, ekCiphertext))
        bytes ekCiphertext; // actual encrypted K-for-buyer payload posted on-chain
    }

    uint256 public nextItemId = 1;
    mapping(uint256 => Item) private items;

    event ItemCreated(
        uint256 indexed itemId,
        address indexed seller,
        uint256 priceWei,
        bytes32 encUriPointerHash,
        bytes32 ciphertextHash,
        bytes32 kHash
    );

    event ItemCancelled(uint256 indexed itemId);

    /// @notice Raw buyer pubkey is not emitted/stored; only hash is recorded.
    event ItemBought(
        uint256 indexed itemId, address indexed buyer, uint256 priceWei, uint64 deadline, bytes32 buyerPubKeyHash
    );

    event ItemDelivered(uint256 indexed itemId, bytes32 ekHash, bytes32 deliveryReceiptHash);
    event ItemRefunded(uint256 indexed itemId, address indexed buyer, uint256 amountWei);

    error ItemNotFound();
    error NotSeller();
    error NotBuyer();
    error BadState();
    error BadPrice();
    error InvalidParams();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error EmptyValue();
    error BuyerPubKeyMismatch();
    error PayFail();
    error RefundFail();

    modifier itemExists(uint256 itemId) {
        _itemExists(itemId);
        _;
    }

    function _itemExists(uint256 itemId) internal view {
        if (!items[itemId].exists) revert ItemNotFound();
    }

    modifier onlySeller(uint256 itemId) {
        _onlySeller(itemId);
        _;
    }

    modifier onlyBuyer(uint256 itemId) {
        _onlyBuyer(itemId);
        _;
    }

    function _onlySeller(uint256 itemId) internal view {
        if (items[itemId].seller != msg.sender) revert NotSeller();
    }

    function _onlyBuyer(uint256 itemId) internal view {
        if (items[itemId].buyer != msg.sender) revert NotBuyer();
    }

    function createItem(
        uint256 priceWei,
        string calldata encUriPointer,
        bytes32 encUriPointerHash,
        bytes32 ciphertextHash,
        bytes32 kHash
    ) external returns (uint256 itemId) {
        if (priceWei == 0) revert InvalidParams();
        if (bytes(encUriPointer).length == 0) revert InvalidParams();
        if (encUriPointerHash == bytes32(0)) revert InvalidParams();
        if (keccak256(bytes(encUriPointer)) != encUriPointerHash) revert InvalidParams();
        if (ciphertextHash == bytes32(0)) revert InvalidParams();
        if (kHash == bytes32(0)) revert InvalidParams();

        itemId = nextItemId++;

        Item storage it = items[itemId];
        it.exists = true;

        it.seller = msg.sender;
        it.buyer = address(0);
        it.priceWei = priceWei;
        it.encUriPointer = encUriPointer;
        it.encUriPointerHash = encUriPointerHash;
        it.ciphertextHash = ciphertextHash;
        it.kHash = kHash;
        it.buyerPubKeyHash = bytes32(0);
        it.deadline = 0;
        it.state = State.Listed;
        it.ekHash = bytes32(0);
        it.deliveryReceiptHash = bytes32(0);
        it.ekCiphertext = "";

        emit ItemCreated(itemId, msg.sender, priceWei, encUriPointerHash, ciphertextHash, kHash);
    }

    /// @notice Seller may cancel before purchase.
    function cancelItem(uint256 itemId) external itemExists(itemId) onlySeller(itemId) {
        Item storage it = items[itemId];
        if (it.state != State.Listed) revert BadState();
        it.state = State.Cancelled;
        emit ItemCancelled(itemId);
    }

    /// @notice Buyer purchases item and provides raw buyer pubkey (public calldata); contract stores only hash.
    /// @param refundWindowSeconds how long buyer is willing to wait for EK delivery before being able to refund.
    function buy(uint256 itemId, bytes calldata buyerPubKey, uint64 refundWindowSeconds)
        external
        payable
        itemExists(itemId)
    {
        Item storage it = items[itemId];
        if (it.state != State.Listed) revert BadState();
        if (msg.value != it.priceWei) revert BadPrice();
        if (buyerPubKey.length == 0) revert InvalidParams();
        if (refundWindowSeconds < MIN_REFUND_WINDOW || refundWindowSeconds > MAX_REFUND_WINDOW) revert InvalidParams();

        it.buyer = msg.sender;
        it.buyerPubKeyHash = keccak256(buyerPubKey);
        it.deadline = uint64(block.timestamp) + refundWindowSeconds;
        it.state = State.Paid;

        emit ItemBought(itemId, msg.sender, it.priceWei, it.deadline, it.buyerPubKeyHash);
    }

    /// @notice Seller posts actual EK ciphertext on-chain and gets paid.
    /// @dev Requires matching buyer pubkey hash to avoid arbitrary delivery data.
    function deliver(uint256 itemId, bytes calldata buyerPubKey, bytes calldata ekCiphertext)
        external
        itemExists(itemId)
        onlySeller(itemId)
        nonReentrant
    {
        Item storage it = items[itemId];
        if (it.state != State.Paid) revert BadState();
        if (buyerPubKey.length == 0) revert InvalidParams();
        if (keccak256(buyerPubKey) != it.buyerPubKeyHash) revert BuyerPubKeyMismatch();
        if (ekCiphertext.length == 0) revert EmptyValue();
        if (block.timestamp > it.deadline) revert DeadlinePassed();

        it.ekHash = keccak256(ekCiphertext);
        it.deliveryReceiptHash = keccak256(abi.encode(itemId, it.buyer, it.buyerPubKeyHash, ekCiphertext));
        it.ekCiphertext = ekCiphertext;
        it.state = State.Committed;

        (bool ok,) = it.seller.call{value: it.priceWei}("");
        if (!ok) revert PayFail();

        emit ItemDelivered(itemId, it.ekHash, it.deliveryReceiptHash);
    }

    /// @notice Buyer refunds only if seller did not deliver EK ciphertext by deadline.
    function refund(uint256 itemId) external itemExists(itemId) onlyBuyer(itemId) nonReentrant {
        Item storage it = items[itemId];
        if (it.state != State.Paid) revert BadState();
        if (block.timestamp <= it.deadline) revert DeadlineNotPassed();

        it.state = State.Refunded;

        (bool ok,) = it.buyer.call{value: it.priceWei}("");
        if (!ok) revert RefundFail();

        emit ItemRefunded(itemId, it.buyer, it.priceWei);
    }

    // Convenience getters

    function getState(uint256 itemId) external view itemExists(itemId) returns (State) {
        return items[itemId].state;
    }

    function getBuyerPubKeyHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].buyerPubKeyHash;
    }

    function getEkHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].ekHash;
    }

    function getDeliveryReceiptHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].deliveryReceiptHash;
    }

    function getEkCiphertext(uint256 itemId) external view itemExists(itemId) returns (bytes memory) {
        return items[itemId].ekCiphertext;
    }

    /// @notice Canonical receipt hash for off-chain EK delivery verification.
    /// @dev Recommended preimage:
    ///      keccak256(abi.encode(itemId, buyer, buyerPubKeyHash, ekCiphertext))
    function hashDeliveryReceipt(uint256 itemId, address buyer, bytes32 buyerPubKeyHash, bytes calldata ekCiphertext)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(itemId, buyer, buyerPubKeyHash, ekCiphertext));
    }

    function getEncUriPointer(uint256 itemId) external view itemExists(itemId) returns (string memory) {
        return items[itemId].encUriPointer;
    }

    function getEncUriPointerHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].encUriPointerHash;
    }

    function getCiphertextHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].ciphertextHash;
    }

    function getKHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].kHash;
    }

    function getDeadline(uint256 itemId) external view itemExists(itemId) returns (uint64) {
        return items[itemId].deadline;
    }

    /// @notice UI-friendly aggregate getter.
    function getItem(uint256 itemId)
        external
        view
        itemExists(itemId)
        returns (address seller, address buyer, uint256 priceWei, uint64 deadline, State state)
    {
        Item storage it = items[itemId];
        return (it.seller, it.buyer, it.priceWei, it.deadline, it.state);
    }
}
