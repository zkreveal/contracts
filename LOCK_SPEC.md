# zkReveal Lock Spec (Inventory + Escrow)

This file freezes the current v0 architecture and naming for `ZkRevealStore`.

## Locked Model

- Seller identity is `address`.
- `Product` is the reusable listing and price source.
- `ProductItem` is one inventory unit under a product.
- `Escrow` is one purchase lifecycle tied to exactly one allocated product item.

Core storage relations:

- `products[productId]`
- `productItems[itemId]`
- `escrows[escrowId]`
- `productsBySeller[seller]`
- `productItemIds[productId]`

ID counters:

- `nextProductId`
- `nextItemId`
- `nextEscrowId`

## Locked Invariants

1. Buyer purchases a product, never picks an item id directly.
2. Item allocation is sequential via `product.nextItemIndex`.
3. Once allocated, a `ProductItem` is permanently `consumed = true` (no recycling on reclaim).
4. Escrow lifecycle is single path: `Pending -> Delivered` or `Pending -> Reclaimed`.
5. Funds only leave contract through `deliverEscrow` (to seller) or `reclaimEscrow` (to buyer).
6. Window bounds are enforced globally:
   - `MIN_REFUND_WINDOW = 5 minutes`
   - `MAX_REFUND_WINDOW = 30 days`
7. v0 is trusted-seller mode:
   - `deliverEscrow` only requires a non-empty payload
   - payload correctness and buyer-side decryptability are off-chain concerns
8. Escrow contents are not private on-chain:
   - `buyerPubKey` and `encryptedKey` are stored in escrow state
   - `contentCID` is stored on each allocated `ProductItem`

## Product Semantics

`Product.unitPrice` is per-item price.  
`Product.totalItems` counts all items ever added.  
`Product.soldItems` counts all allocated/consumed items.  
`Product.active` gates new escrow creation only.

## Function Contract (Inputs and State Usage)

### `createProduct(title, unitPrice, refundWindow) -> productId`

Inputs:

- `title`
- `unitPrice`
- `refundWindow`

Validation:

- title non-empty
- unitPrice > 0
- refundWindow in `[MIN_REFUND_WINDOW, MAX_REFUND_WINDOW]`

Writes:

- creates `products[productId]`
- appends `productId` to `productsBySeller[msg.sender]`

Emits:

- `ProductCreated`

### `addItemsToProduct(productId, contentCIDs[])`

Inputs:

- `productId`
- `contentCIDs`

Validation:

- product exists
- caller is product seller
- array length > 0
- each CID non-empty

Writes:

- creates new `productItems[itemId]` entries
- appends each `itemId` to `productItemIds[productId]`
- increments `products[productId].totalItems`

Emits:

- `ProductItemsAdded`

### `setProductActive(productId, active)`

Inputs:

- `productId`
- `active`

Validation:

- product exists
- caller is product seller

Writes:

- `products[productId].active`

Emits:

- `ProductStatusChanged`

### `createEscrow(productId, buyerPubKey) payable -> escrowId`

Inputs:

- `productId`
- `buyerPubKey`
- `msg.value`

Validation:

- product exists
- product active
- buyerPubKey non-empty
- `msg.value == products[productId].unitPrice`
- inventory available through `_allocateNextProductItem`

Writes:

- allocates item id sequentially
- marks allocated `productItems[itemId].consumed = true`
- increments `products[productId].nextItemIndex`
- increments `products[productId].soldItems`
- creates `escrows[escrowId]` with:
  - `productId`, `itemId`, `seller`, `buyer`, `amount`
  - `buyerPubKey`, `encryptedKey = ""`
  - `createdAt`, `deadline`, `status = Pending`

Emits:

- `EscrowCreated`

### `deliverEscrow(escrowId, encryptedKey)`

Inputs:

- `escrowId`
- `encryptedKey`

Validation:

- escrow exists
- caller is escrow seller
- escrow status is `Pending`
- `encryptedKey` non-empty
- current time must be less than or equal to escrow deadline

Writes:

- stores `escrow.encryptedKey`
- sets `escrow.status = Delivered`

External transfer:

- transfers `escrow.amount` to seller

Emits:

- `EscrowDelivered`

Trust boundary:

- the contract does not verify whether `encryptedKey` is valid for the buyer or bound to the allocated item

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

- `ProductCreated(uint256,address,string,uint256,uint64)`
- `ProductItemsAdded(uint256,uint256)`
- `ProductStatusChanged(uint256,bool)`
- `EscrowCreated(uint256,uint256,uint256,address,address,uint256)`
- `EscrowDelivered(uint256)`
- `EscrowReclaimed(uint256)`
