// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRakeEngine {
    function maxProtocolFeeBps() external view returns (uint16);

    function quoteDeliveryRake(address seller, uint256 listingId, uint256 grossAmount)
        external
        view
        returns (address recipient, uint256 feeAmount);

    function getEffectiveFeeBps(address seller, uint256 listingId) external view returns (uint16);
}
