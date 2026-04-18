// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {RakeEngine} from "../src/RakeEngine.sol";

contract RakeEngineTest is Test {
    RakeEngine rakeEngine;

    event FeeRecipientSet(address indexed feeRecipient);
    event DefaultFeeBpsSet(uint16 feeBps);
    event SellerFeeBpsOverrideSet(address indexed seller, uint16 feeBps);
    event ListingFeeBpsOverrideCleared(uint256 indexed listingId);

    address owner = address(0xA11CE);
    address aliceSeller = address(0xBEEF);
    address bobSeller = address(0xB0B);
    address feeRecipient = address(0xFEE);
    address otherRecipient = address(0xFACE);
    address attacker = address(0xD00D);

    uint16 defaultFeeBps = 250;

    function setUp() public {
        rakeEngine = new RakeEngine(owner, feeRecipient, defaultFeeBps);
    }

    function test_Constructor_SetsFeeRecipient() public view {
        assertEq(rakeEngine.feeRecipient(), feeRecipient);
    }

    function test_Constructor_SetsDefaultFeeBps() public view {
        assertEq(rakeEngine.defaultFeeBps(), defaultFeeBps);
    }

    function test_Constructor_ExposesMaxBps() public view {
        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(aliceSeller, 1, 10_000);

        assertEq(feeAmount, 250);
    }

    function test_Constructor_ExposesMaxProtocolFeeBps() public view {
        assertEq(rakeEngine.MAX_PROTOCOL_FEE_BPS(), 1_000);
    }

    function test_MaxProtocolFeeBps_ReturnsCap() public view {
        assertEq(rakeEngine.maxProtocolFeeBps(), 1_000);
    }

    function test_Constructor_ZeroOwnerReverts() public {
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        new RakeEngine(address(0), feeRecipient, defaultFeeBps);
    }

    function test_Constructor_ZeroFeeRecipientReverts() public {
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        new RakeEngine(owner, address(0), defaultFeeBps);
    }

    function test_Constructor_DefaultFeeAboveCapReverts() public {
        uint16 tooHigh = uint16(rakeEngine.MAX_PROTOCOL_FEE_BPS() + 1);

        vm.expectRevert(RakeEngine.FeeTooHigh.selector);
        new RakeEngine(owner, feeRecipient, tooHigh);
    }

    function test_SetFeeRecipient_OwnerCanSetNewRecipient() public {
        vm.prank(owner);
        rakeEngine.setFeeRecipient(otherRecipient);

        assertEq(rakeEngine.feeRecipient(), otherRecipient);
    }

    function test_SetFeeRecipient_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit FeeRecipientSet(otherRecipient);

        vm.prank(owner);
        rakeEngine.setFeeRecipient(otherRecipient);
    }

    function test_SetFeeRecipient_ZeroRecipientReverts() public {
        vm.prank(owner);
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        rakeEngine.setFeeRecipient(address(0));
    }

    function test_SetFeeRecipient_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.setFeeRecipient(otherRecipient);
    }

    function test_SetDefaultFeeBps_OwnerCanSetValidFee() public {
        vm.prank(owner);
        rakeEngine.setDefaultFeeBps(500);

        assertEq(rakeEngine.defaultFeeBps(), 500);
    }

    function test_SetDefaultFeeBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit DefaultFeeBpsSet(500);

        vm.prank(owner);
        rakeEngine.setDefaultFeeBps(500);
    }

    function test_SetDefaultFeeBps_AllowsZero() public {
        vm.prank(owner);
        rakeEngine.setDefaultFeeBps(0);

        assertEq(rakeEngine.defaultFeeBps(), 0);
    }

    function test_SetDefaultFeeBps_AboveCapReverts() public {
        uint16 tooHigh = uint16(rakeEngine.MAX_PROTOCOL_FEE_BPS() + 1);

        vm.prank(owner);
        vm.expectRevert(RakeEngine.FeeTooHigh.selector);
        rakeEngine.setDefaultFeeBps(tooHigh);
    }

    function test_SetDefaultFeeBps_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.setDefaultFeeBps(500);
    }

    function test_SetSellerFeeExempt_OwnerCanSetTrueAndFalse() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeExempt(aliceSeller, true);

        assertEq(rakeEngine.sellerFeeExempt(aliceSeller), true);

        vm.prank(owner);
        rakeEngine.setSellerFeeExempt(aliceSeller, false);

        assertEq(rakeEngine.sellerFeeExempt(aliceSeller), false);
    }

    function test_SetSellerFeeExempt_ZeroSellerReverts() public {
        vm.prank(owner);
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        rakeEngine.setSellerFeeExempt(address(0), true);
    }

    function test_SetSellerFeeExempt_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.setSellerFeeExempt(aliceSeller, true);
    }

    function test_SetSellerFeeBpsOverride_OwnerCanSetValidOverride() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);

        assertEq(rakeEngine.hasSellerFeeBpsOverride(aliceSeller), true);
        assertEq(rakeEngine.sellerFeeBpsOverride(aliceSeller), 500);
    }

    function test_SetSellerFeeBpsOverride_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit SellerFeeBpsOverrideSet(aliceSeller, 500);

        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
    }

    function test_SetSellerFeeBpsOverride_OwnerCanExplicitlySetZero() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 0);

        assertEq(rakeEngine.hasSellerFeeBpsOverride(aliceSeller), true);
        assertEq(rakeEngine.sellerFeeBpsOverride(aliceSeller), 0);
    }

    function test_SetSellerFeeBpsOverride_ZeroSellerReverts() public {
        vm.prank(owner);
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        rakeEngine.setSellerFeeBpsOverride(address(0), 500);
    }

    function test_SetSellerFeeBpsOverride_AboveCapReverts() public {
        uint16 tooHigh = uint16(rakeEngine.MAX_PROTOCOL_FEE_BPS() + 1);

        vm.prank(owner);
        vm.expectRevert(RakeEngine.FeeTooHigh.selector);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, tooHigh);
    }

    function test_SetSellerFeeBpsOverride_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
    }

    function test_ClearSellerFeeBpsOverride_ClearsPresenceAndStoredValue() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.clearSellerFeeBpsOverride(aliceSeller);
        vm.stopPrank();

        assertEq(rakeEngine.hasSellerFeeBpsOverride(aliceSeller), false);
        assertEq(rakeEngine.sellerFeeBpsOverride(aliceSeller), 0);
    }

    function test_ClearSellerFeeBpsOverride_ZeroSellerReverts() public {
        vm.prank(owner);
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        rakeEngine.clearSellerFeeBpsOverride(address(0));
    }

    function test_ClearSellerFeeBpsOverride_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.clearSellerFeeBpsOverride(aliceSeller);
    }

    function test_SetListingFeeBpsOverride_OwnerCanSetValidOverride() public {
        vm.prank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 500);

        assertEq(rakeEngine.hasListingFeeBpsOverride(7), true);
        assertEq(rakeEngine.listingFeeBpsOverride(7), 500);
    }

    function test_SetListingFeeBpsOverride_OwnerCanExplicitlySetZero() public {
        vm.prank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 0);

        assertEq(rakeEngine.hasListingFeeBpsOverride(7), true);
        assertEq(rakeEngine.listingFeeBpsOverride(7), 0);
    }

    function test_SetListingFeeBpsOverride_ZeroListingIdReverts() public {
        vm.prank(owner);
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        rakeEngine.setListingFeeBpsOverride(0, 500);
    }

    function test_SetListingFeeBpsOverride_AboveCapReverts() public {
        uint16 tooHigh = uint16(rakeEngine.MAX_PROTOCOL_FEE_BPS() + 1);

        vm.prank(owner);
        vm.expectRevert(RakeEngine.FeeTooHigh.selector);
        rakeEngine.setListingFeeBpsOverride(7, tooHigh);
    }

    function test_SetListingFeeBpsOverride_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.setListingFeeBpsOverride(7, 500);
    }

    function test_ClearListingFeeBpsOverride_ClearsPresenceAndStoredValue() public {
        vm.startPrank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 500);
        rakeEngine.clearListingFeeBpsOverride(7);
        vm.stopPrank();

        assertEq(rakeEngine.hasListingFeeBpsOverride(7), false);
        assertEq(rakeEngine.listingFeeBpsOverride(7), 0);
    }

    function test_ClearListingFeeBpsOverride_EmitsEvent() public {
        vm.prank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 500);

        vm.expectEmit(true, false, false, true);
        emit ListingFeeBpsOverrideCleared(7);

        vm.prank(owner);
        rakeEngine.clearListingFeeBpsOverride(7);
    }

    function test_ClearListingFeeBpsOverride_ZeroListingIdReverts() public {
        vm.prank(owner);
        vm.expectRevert(RakeEngine.InvalidParams.selector);
        rakeEngine.clearListingFeeBpsOverride(0);
    }

    function test_ClearListingFeeBpsOverride_NonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        rakeEngine.clearListingFeeBpsOverride(7);
    }

    function test_GetEffectiveFeeBps_NoOverrideReturnsDefault() public view {
        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 1), defaultFeeBps);
    }

    function test_GetEffectiveFeeBps_SellerOverrideOnlyReturnsSellerOverride() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 1), 500);
    }

    function test_GetEffectiveFeeBps_ListingOverrideOnlyReturnsListingOverride() public {
        vm.prank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 600);

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 600);
    }

    function test_GetEffectiveFeeBps_ListingOverrideWinsOverSellerOverride() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.setListingFeeBpsOverride(7, 600);
        vm.stopPrank();

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 600);
    }

    function test_GetEffectiveFeeBps_SellerExemptWinsOverSellerOverride() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.setSellerFeeExempt(aliceSeller, true);
        vm.stopPrank();

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 0);
    }

    function test_GetEffectiveFeeBps_SellerExemptWinsOverListingOverride() public {
        vm.startPrank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 600);
        rakeEngine.setSellerFeeExempt(aliceSeller, true);
        vm.stopPrank();

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 0);
    }

    function test_GetEffectiveFeeBps_SellerExemptWinsOverBothOverrides() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.setListingFeeBpsOverride(7, 600);
        rakeEngine.setSellerFeeExempt(aliceSeller, true);
        vm.stopPrank();

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 0);
    }

    function test_GetEffectiveFeeBps_ExplicitZeroSellerOverrideReturnsZero() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 0);

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 0);
    }

    function test_GetEffectiveFeeBps_ExplicitZeroListingOverrideBeatsSellerOverride() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.setListingFeeBpsOverride(7, 0);
        vm.stopPrank();

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 0);
    }

    function test_GetEffectiveFeeBps_ClearingOverridesRestoresFallbackBehavior() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.setListingFeeBpsOverride(7, 600);
        vm.stopPrank();

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 600);

        vm.prank(owner);
        rakeEngine.clearListingFeeBpsOverride(7);

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), 500);

        vm.prank(owner);
        rakeEngine.clearSellerFeeBpsOverride(aliceSeller);

        assertEq(rakeEngine.getEffectiveFeeBps(aliceSeller, 7), defaultFeeBps);
    }

    function test_QuoteDeliveryRake_ReturnsFeeRecipient() public view {
        (address recipient,) = rakeEngine.quoteDeliveryRake(aliceSeller, 1, 1 ether);

        assertEq(recipient, feeRecipient);
    }

    function test_QuoteDeliveryRake_DefaultFeeMathIsCorrect() public view {
        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(aliceSeller, 1, 1 ether);

        assertEq(feeAmount, 0.025 ether);
    }

    function test_QuoteDeliveryRake_SellerOverrideFeeMathIsCorrect() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);

        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(aliceSeller, 1, 1000);

        assertEq(feeAmount, 50);
    }

    function test_QuoteDeliveryRake_ListingOverrideFeeMathIsCorrect() public {
        vm.prank(owner);
        rakeEngine.setListingFeeBpsOverride(7, 300);

        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(bobSeller, 7, 1 ether);

        assertEq(feeAmount, 0.03 ether);
    }

    function test_QuoteDeliveryRake_ExemptSellerReturnsZeroFee() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeExempt(aliceSeller, true);

        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(aliceSeller, 1, 1 ether);

        assertEq(feeAmount, 0);
    }

    function test_QuoteDeliveryRake_ExplicitZeroOverrideReturnsZeroFee() public {
        vm.prank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 0);

        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(aliceSeller, 1, 1000);

        assertEq(feeAmount, 0);
    }

    function test_QuoteDeliveryRake_ExplicitZeroListingOverrideReturnsZeroFee() public {
        vm.startPrank(owner);
        rakeEngine.setSellerFeeBpsOverride(aliceSeller, 500);
        rakeEngine.setListingFeeBpsOverride(7, 0);
        vm.stopPrank();

        (, uint256 feeAmount) = rakeEngine.quoteDeliveryRake(aliceSeller, 7, 1000);

        assertEq(feeAmount, 0);
    }
}
