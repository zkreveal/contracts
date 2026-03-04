// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ZkRevealStore (Trusted Seller v2 - Privacy Preserving)
/// @notice Seller is trusted to deliver a valid EK to the buyer off-chain.
///         Contract enforces: single-buyer purchase, escrow, deadline-based refund if seller never commits delivery.
///         If seller commits delivery before deadline, seller is paid immediately.
/// @dev Raw buyerPubKey and EK are never stored on-chain; only commitments are recorded.
contract ZkRevealStore is ReentrancyGuard {
    enum State {
        Listed,
        Paid, // buyer paid, waiting for seller EK
        Revealed, // EK posted, seller paid
        Refunded,
        Cancelled
    }

    struct Item {
        bool exists;

        address seller;
        address buyer;

        uint256 priceWei;
        string ciphertextURI; // pointer to encrypted secret blob (AES-GCM)

        bytes32 buyerPubKeyHash; // hash commitment to buyer encryption pubkey (recommend salted hash)
        uint64 deadline; // refund deadline (unix time)
        State state;

        bytes32 deliveryHash; // hash commitment to delivered EK payload (recommend salted hash)
    }

    uint256 public nextItemId = 1;
    mapping(uint256 => Item) public items;

    event ItemCreated(uint256 indexed itemId, address indexed seller, uint256 priceWei, string ciphertextURI);

    event ItemCancelled(uint256 indexed itemId);

    /// @notice buyerPubKey is NOT emitted (privacy). We emit only a hash.
    event ItemBought(
        uint256 indexed itemId, address indexed buyer, uint256 priceWei, uint64 deadline, bytes32 buyerPubKeyHash
    );

    event DeliveryCommitted(uint256 indexed itemId, bytes32 deliveryHash);
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

    function createItem(uint256 priceWei, string calldata ciphertextURI) external returns (uint256 itemId) {
        if (priceWei == 0) revert InvalidParams();
        if (bytes(ciphertextURI).length == 0) revert InvalidParams();

        itemId = nextItemId++;

        Item storage it = items[itemId];
        it.exists = true;

        it.seller = msg.sender;
        it.buyer = address(0);
        it.priceWei = priceWei;
        it.ciphertextURI = ciphertextURI;
        it.buyerPubKeyHash = bytes32(0);
        it.deadline = 0;
        it.state = State.Listed;
        it.deliveryHash = bytes32(0);

        emit ItemCreated(itemId, msg.sender, priceWei, ciphertextURI);
    }

    /// @notice Seller may cancel before purchase.
    function cancelItem(uint256 itemId) external itemExists(itemId) onlySeller(itemId) {
        Item storage it = items[itemId];
        if (it.state != State.Listed) revert BadState();
        it.state = State.Cancelled;
        emit ItemCancelled(itemId);
    }

    /// @notice Buyer purchases item and provides a pubkey commitment for private delivery.
    /// @param refundWindowSeconds how long buyer is willing to wait for reveal before being able to refund.
    function buy(uint256 itemId, bytes32 buyerPubKeyHash, uint64 refundWindowSeconds)
        external
        payable
        itemExists(itemId)
    {
        Item storage it = items[itemId];
        if (it.state != State.Listed) revert BadState();
        if (msg.value != it.priceWei) revert BadPrice();
        if (buyerPubKeyHash == bytes32(0)) revert InvalidParams();
        if (refundWindowSeconds == 0) revert InvalidParams();

        it.buyer = msg.sender;
        it.buyerPubKeyHash = buyerPubKeyHash;
        it.deadline = uint64(block.timestamp) + refundWindowSeconds;
        it.state = State.Paid;

        emit ItemBought(itemId, msg.sender, it.priceWei, it.deadline, buyerPubKeyHash);
    }

    /// @notice Seller commits a delivery hash for off-chain EK delivery.
    ///         Under trusted seller assumption, contract does not validate correctness.
    ///         Seller is paid immediately upon commit.
    function commitDelivery(uint256 itemId, bytes32 deliveryHash) external itemExists(itemId) onlySeller(itemId) nonReentrant {
        Item storage it = items[itemId];
        if (it.state != State.Paid) revert BadState();
        if (deliveryHash == bytes32(0)) revert EmptyValue();
        if (block.timestamp > it.deadline) revert DeadlinePassed();

        it.deliveryHash = deliveryHash;
        it.state = State.Revealed;

        (bool ok,) = it.seller.call{value: it.priceWei}("");
        require(ok, "PAY_FAIL");

        emit DeliveryCommitted(itemId, deliveryHash);
    }

    /// @notice Buyer refunds only if seller did not reveal by deadline.
    function refund(uint256 itemId) external itemExists(itemId) onlyBuyer(itemId) nonReentrant {
        Item storage it = items[itemId];
        if (it.state != State.Paid) revert BadState();
        if (block.timestamp <= it.deadline) revert DeadlineNotPassed();

        it.state = State.Refunded;

        (bool ok,) = it.buyer.call{value: it.priceWei}("");
        require(ok, "REFUND_FAIL");

        emit ItemRefunded(itemId, it.buyer, it.priceWei);
    }

    // Convenience getters

    function getState(uint256 itemId) external view itemExists(itemId) returns (State) {
        return items[itemId].state;
    }

    function getBuyerPubKeyHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].buyerPubKeyHash;
    }

    function getDeliveryHash(uint256 itemId) external view itemExists(itemId) returns (bytes32) {
        return items[itemId].deliveryHash;
    }

    function getDeadline(uint256 itemId) external view itemExists(itemId) returns (uint64) {
        return items[itemId].deadline;
    }

    /// @notice UI-friendly aggregate getter.
    function getItem(uint256 itemId)
        external
        view
        itemExists(itemId)
        returns (
            address seller,
            address buyer,
            uint256 priceWei,
            string memory ciphertextURI,
            uint64 deadline,
            State state
        )
    {
        Item storage it = items[itemId];
        return (it.seller, it.buyer, it.priceWei, it.ciphertextURI, it.deadline, it.state);
    }
}
