// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FeeMath} from "./FeeMath.sol";
import {IRakeEngine} from "./IRakeEngine.sol";

/// @title RakeEngine
/// @notice Fee policy engine for zkReveal delivery settlements.
/// @dev Refunds do not incur protocol fees. Explicit 0 bps overrides are supported via separate presence flags.
contract RakeEngine is Ownable, IRakeEngine {
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1_000;

    address public feeRecipient;
    uint16 public defaultFeeBps;

    mapping(address => bool) public sellerFeeExempt;

    mapping(address => bool) public hasSellerFeeBpsOverride;
    mapping(address => uint16) public sellerFeeBpsOverride;

    mapping(uint256 => bool) public hasListingFeeBpsOverride;
    mapping(uint256 => uint16) public listingFeeBpsOverride;

    error InvalidParams();
    error FeeTooHigh();

    event FeeRecipientSet(address indexed feeRecipient);
    event DefaultFeeBpsSet(uint16 feeBps);
    event SellerFeeExemptSet(address indexed seller, bool exempt);
    event SellerFeeBpsOverrideSet(address indexed seller, uint16 feeBps);
    event SellerFeeBpsOverrideCleared(address indexed seller);
    event ListingFeeBpsOverrideSet(uint256 indexed listingId, uint16 feeBps);
    event ListingFeeBpsOverrideCleared(uint256 indexed listingId);

    constructor(address initialOwner, address initialFeeRecipient, uint16 initialDefaultFeeBps)
        Ownable(_requireOwner(initialOwner))
    {
        if (initialFeeRecipient == address(0)) revert InvalidParams();
        if (initialDefaultFeeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();

        feeRecipient = initialFeeRecipient;
        defaultFeeBps = initialDefaultFeeBps;

        emit FeeRecipientSet(initialFeeRecipient);
        emit DefaultFeeBpsSet(initialDefaultFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidParams();

        feeRecipient = newRecipient;

        emit FeeRecipientSet(newRecipient);
    }

    function setDefaultFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();

        defaultFeeBps = newFeeBps;

        emit DefaultFeeBpsSet(newFeeBps);
    }

    function setSellerFeeExempt(address seller, bool exempt) external onlyOwner {
        if (seller == address(0)) revert InvalidParams();

        sellerFeeExempt[seller] = exempt;

        emit SellerFeeExemptSet(seller, exempt);
    }

    function setSellerFeeBpsOverride(address seller, uint16 feeBps) external onlyOwner {
        if (seller == address(0)) revert InvalidParams();
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();

        hasSellerFeeBpsOverride[seller] = true;
        sellerFeeBpsOverride[seller] = feeBps;

        emit SellerFeeBpsOverrideSet(seller, feeBps);
    }

    function clearSellerFeeBpsOverride(address seller) external onlyOwner {
        if (seller == address(0)) revert InvalidParams();

        delete hasSellerFeeBpsOverride[seller];
        delete sellerFeeBpsOverride[seller];

        emit SellerFeeBpsOverrideCleared(seller);
    }

    function setListingFeeBpsOverride(uint256 listingId, uint16 feeBps) external onlyOwner {
        if (listingId == 0) revert InvalidParams();
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();

        hasListingFeeBpsOverride[listingId] = true;
        listingFeeBpsOverride[listingId] = feeBps;

        emit ListingFeeBpsOverrideSet(listingId, feeBps);
    }

    function clearListingFeeBpsOverride(uint256 listingId) external onlyOwner {
        if (listingId == 0) revert InvalidParams();

        delete hasListingFeeBpsOverride[listingId];
        delete listingFeeBpsOverride[listingId];

        emit ListingFeeBpsOverrideCleared(listingId);
    }

    function quoteDeliveryRake(address seller, uint256 listingId, uint256 grossAmount)
        external
        view
        returns (address recipient, uint256 feeAmount)
    {
        uint16 feeBps = getEffectiveFeeBps(seller, listingId);

        recipient = feeRecipient;
        feeAmount = grossAmount * feeBps / FeeMath.BPS_DENOMINATOR;
    }

    function maxProtocolFeeBps() external pure returns (uint16) {
        return MAX_PROTOCOL_FEE_BPS;
    }

    function getEffectiveFeeBps(address seller, uint256 listingId) public view returns (uint16) {
        if (sellerFeeExempt[seller]) {
            return 0;
        }

        if (hasListingFeeBpsOverride[listingId]) {
            return listingFeeBpsOverride[listingId];
        }

        if (hasSellerFeeBpsOverride[seller]) {
            return sellerFeeBpsOverride[seller];
        }

        return defaultFeeBps;
    }

    function _requireOwner(address owner_) private pure returns (address) {
        if (owner_ == address(0)) revert InvalidParams();
        return owner_;
    }
}
