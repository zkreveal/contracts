# Reveal Protocol Lock Spec (Inventory + Escrow)

This file freezes the current v0 architecture and naming for `RevealDeliveryStore`.

## Locked Model

- Seller identity is `address`.
- `Listing` is the reusable sale entry and price source.
- `InventoryUnit` is one inventory unit under a listing, with `contentCID` assigned at delivery time.
- `Escrow` is one purchase lifecycle tied to exactly one allocated inventory unit.

Core storage relations:

- `listings[listingId]`
- `inventoryUnits[inventoryUnitId]`
- `escrows[escrowId]`
- `listingsBySeller[seller]`
- `listingInventoryUnitIds[listingId]`

ID counters:

- `nextListingId`
- `nextInventoryUnitId`
- `nextEscrowId`

## Locked Invariants

1. Buyer purchases a listing, never picks an inventory unit id directly.
2. Inventory allocation is sequential via `listing.nextInventoryUnitIndex`.
3. Once allocated, an `InventoryUnit` is permanently `consumed = true` (no recycling on reclaim).
4. Escrow lifecycle is single path: `Pending -> Delivered` or `Pending -> Reclaimed`.
5. Funds only leave contract through `deliverEscrow` (to seller) or `reclaimEscrow` (to buyer).
6. Window bounds are enforced globally:
   - `MIN_REFUND_WINDOW = 5 minutes`
   - `MAX_REFUND_WINDOW = 30 days`
7. v0 is trusted-seller mode:
   - `deliverEscrow` only requires non-empty `contentCID` and `encryptedKey`
   - payload correctness and buyer-side decryptability are off-chain concerns
8. Escrow contents are not private on-chain:
   - `buyerPubKey` and `encryptedKey` are stored in escrow state
   - delivered `contentCID` is stored on each fulfilled `InventoryUnit`

## Listing Semantics

`Listing.title` is human-readable display text.  
`Listing.resourceId` is a seller-defined, machine-readable, non-normalized semantic identifier.  
`listingId` remains the canonical protocol-local on-chain identifier.  
`Listing.unitPrice` is per-unit price.  
`Listing.totalInventoryUnits` counts all units ever added.  
`Listing.soldInventoryUnits` counts all allocated/consumed units.  
`Listing.active` gates new delivery purchases only.

## Integration Safety

Do not key claims by bare `resourceId`.

Preferred canonical off-chain identity:

- `(chainId, contractAddress, listingId)`

Preferred off-chain identity:

- `(chainId, contractAddress, seller, resourceId)`

A delivered escrow can be interpreted off-chain as a delivered purchase claim for that identity tuple.

## Function Contract (Inputs and State Usage)

### `createListing(title, resourceId, unitPrice, refundWindow) -> listingId`

Inputs:

- `title`
- `resourceId`
- `unitPrice`
- `refundWindow`

Validation:

- title non-empty
- resourceId non-empty
- unitPrice > 0
- refundWindow in `[MIN_REFUND_WINDOW, MAX_REFUND_WINDOW]`

Writes:

- creates `listings[listingId]`
- appends `listingId` to `listingsBySeller[msg.sender]`

Emits:

- `ListingCreated`

### `addInventoryUnitsToListing(listingId, count)`

Inputs:

- `listingId`
- `count`

Validation:

- listing exists
- caller is listing seller
- count > 0

Writes:

- creates new `inventoryUnits[inventoryUnitId]` entries
- each new unit starts with empty `contentCID`
- appends each `inventoryUnitId` to `listingInventoryUnitIds[listingId]`
- increments `listings[listingId].totalInventoryUnits`

Emits:

- `InventoryUnitAdded`

### `setListingActive(listingId, active)`

Inputs:

- `listingId`
- `active`

Validation:

- listing exists
- caller is listing seller

Writes:

- `listings[listingId].active`

Emits:

- `ListingStatusChanged`

### `purchaseDelivery(listingId, buyerPubKey) payable -> escrowId`

Inputs:

- `listingId`
- `buyerPubKey`
- `msg.value`

Validation:

- listing exists
- listing active
- buyerPubKey non-empty
- `msg.value == listings[listingId].unitPrice`
- inventory available through `_allocateNextInventoryUnit`

Writes:

- allocates inventory unit id sequentially
- marks allocated `inventoryUnits[inventoryUnitId].consumed = true`
- increments `listings[listingId].nextInventoryUnitIndex`
- increments `listings[listingId].soldInventoryUnits`
- creates `escrows[escrowId]` with:
  - `listingId`, `inventoryUnitId`, `seller`, `buyer`, `amount`
  - `buyerPubKey`, `encryptedKey = ""`
  - `createdAt`, `deadline`, `status = Pending`

Emits:

- `EscrowCreated`

### `deliverEscrow(escrowId, contentCID, encryptedKey)`

Inputs:

- `escrowId`
- `contentCID`
- `encryptedKey`

Validation:

- escrow exists
- caller is escrow seller
- escrow status is `Pending`
- `contentCID` non-empty
- `encryptedKey` non-empty
- current time must be less than or equal to escrow deadline

Writes:

- stores `inventoryUnits[escrow.inventoryUnitId].contentCID`
- stores `escrow.encryptedKey`
- sets `escrow.status = Delivered`

External transfer:

- transfers `escrow.amount` to seller

Emits:

- `EscrowDelivered`

Trust boundary:

- the contract does not verify whether `contentCID` or `encryptedKey` are valid for the buyer or bound to the allocated item

### `reclaimEscrow(escrowId)`

Inputs:

- `escrowId`

Validation:

- escrow exists
- caller is escrow buyer
- escrow status is `Pending`
- current time strictly after deadline

Writes:

- sets `escrow.status = Reclaimed`

External transfer:

- refunds `escrow.amount` to buyer

Emits:

- `EscrowReclaimed`

## Locked Events

- `ListingCreated(uint256,address,string,string,uint256,uint64)`
- `InventoryUnitAdded(uint256,uint256)`
- `ListingStatusChanged(uint256,bool)`
- `EscrowCreated(uint256,uint256,uint256,address,address,uint256,string)`
- `EscrowDelivered(uint256,uint256,address,string,string)`
- `EscrowReclaimed(uint256,uint256,address,string)`
