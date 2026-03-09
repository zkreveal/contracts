# ZkReveal v1 Lock Spec (Inventory Model)

This file locks the inventory-based design:

- Seller address is business identity
- Product is a reusable listing with per-item price
- ProductItem is one inventory unit under product
- Escrow is one purchase lifecycle bound to one allocated item

## Core Architecture

- `products[productId]`
- `productItems[itemId]`
- `escrows[escrowId]`
- `productsBySeller[seller]`
- `productItemIds[productId]`

## Product Rules

`createProduct(title, unitPrice, refundWindow)` requires:

- non-empty `title`
- `unitPrice > 0`
- `refundWindow` within `[MIN_REFUND_WINDOW, MAX_REFUND_WINDOW]`

Product semantics:

- `unitPrice` is per-item price
- `active` controls purchasability
- `nextItemIndex` drives sequential allocation
- `totalItems` = items ever added
- `soldItems` = items ever allocated/consumed

## ProductItem Rules

`addItemsToProduct(productId, contentCIDs[])`:

- seller-only
- append-only
- each CID must be non-empty
- each added item has `consumed = false`

Allocation via `_allocateNextProductItem(productId)`:

- sequential only
- marks selected item `consumed = true`
- increments `nextItemIndex` and `soldItems`
- no recycling

## Purchase / Escrow Rules

`createEscrow(productId, buyerPubKey)`:

- buyer buys product (not item)
- exact payment `msg.value == unitPrice`
- product must be active and not sold out
- buyer pubkey must be non-empty
- contract allocates item internally
- escrow stores exact `productId` and `itemId`
- escrow starts in `Pending`

`deliverEscrow(escrowId, encryptedKey)`:

- escrow seller only
- only `Pending`
- before deadline
- non-empty payload
- sets `encryptedKey`
- state -> `Delivered`
- pays seller

`reclaimEscrow(escrowId)`:

- escrow buyer only
- only `Pending`
- after deadline
- state -> `Reclaimed`
- refunds buyer
- consumed item remains consumed

## Locked Events

- `ProductCreated(productId, seller, title, unitPrice, refundWindow)`
- `ProductItemsAdded(productId, count)`
- `ProductStatusChanged(productId, active)`
- `EscrowCreated(escrowId, productId, itemId, seller, buyer, amount)`
- `EscrowDelivered(escrowId)`
- `EscrowReclaimed(escrowId)`
