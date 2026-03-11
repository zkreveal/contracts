# zkReveal

Inventory-based encrypted delivery escrow in Solidity (Foundry project).

## Current Design (v0)

zkReveal uses a hierarchical model:

- `Product`: reusable listing with shared metadata and per-unit price.
- `ProductItem`: one inventory unit under a product, each with its own `contentCID`.
- `Escrow`: one buyer purchase tied to exactly one allocated product item.

Seller identity is the seller wallet address.

## Security Model (v0)

This contract is a trusted-seller delivery escrow, not a trustless proof system.

- `deliverEscrow` only verifies that `encryptedKey` is non-empty and submitted on or before the escrow deadline.
- The contract does not prove that the payload decrypts correctly or matches the allocated item.
- Seller is paid immediately after successful delivery submission.
- Correctness of the delivered payload is verified off-chain by the buyer.

## On-Chain Visibility

The following data is public on-chain or retrievable from contract state:

- `ProductItem.contentCID`
- `Escrow.buyerPubKey`
- `Escrow.encryptedKey`
- escrow timestamps, status, seller, buyer, product id, and item id

The following data is not stored on-chain:

- plaintext content
- buyer private key
- decrypted symmetric key material

## Core Contract

- `src/ZkRevealStore.sol`

Key storage:

- `products[productId]`
- `productItems[itemId]`
- `escrows[escrowId]`
- `productsBySeller[seller]`
- `productItemIds[productId]`

Escrow status:

- `Pending`
- `Delivered`
- `Reclaimed`

## High-Level Flows

### Seller flow

1. Create product via `createProduct(title, unitPrice, refundWindow)`.
2. Add inventory CIDs via `addItemsToProduct(productId, contentCIDs)`.
3. Buyer creates escrow via `createEscrow`.
4. Seller submits a non-empty encrypted delivery payload via `deliverEscrow(escrowId, encryptedKey)`.
5. Contract pays seller immediately on successful delivery submission.

### Buyer flow

1. Generate buyer encryption keypair off-chain.
2. Call `createEscrow(productId, buyerPubKey)` and pay exact `unitPrice`.
3. Wait for seller delivery; read the public `escrow.encryptedKey` from `getEscrow`.
4. Decrypt content key off-chain and use allocated item `contentCID`.
5. If seller misses deadline, call `reclaimEscrow(escrowId)` to refund.

## Function Interface and Data Use

### `createProduct(string title, uint256 unitPrice, uint64 refundWindow)`

Inputs:

- `title`: listing name
- `unitPrice`: price per item
- `refundWindow`: escrow reclaim window

Uses:

- validates non-empty title, non-zero price, and refund window bounds

Writes:

- new `Product`
- `productsBySeller[msg.sender]`

### `addItemsToProduct(uint256 productId, string[] contentCIDs)`

Inputs:

- `productId`
- `contentCIDs`: per-unit encrypted content pointers

Uses:

- caller must be product seller
- every CID must be non-empty

Writes:

- appends `ProductItem` rows
- appends to `productItemIds[productId]`
- increments product `totalItems`

### `setProductActive(uint256 productId, bool active)`

Inputs:

- `productId`
- `active`

Uses:

- caller must be product seller

Writes:

- product availability flag

### `createEscrow(uint256 productId, bytes buyerPubKey) payable`

Inputs:

- `productId`
- `buyerPubKey`
- `msg.value`

Uses:

- product must be active with available inventory
- `msg.value` must equal product `unitPrice`
- internally calls `_allocateNextProductItem(productId)` (sequential allocation)

Writes:

- marks one `ProductItem` as `consumed`
- creates `Escrow` with product/item linkage, buyer/seller, amount, key, timestamps, deadline, status

### `deliverEscrow(uint256 escrowId, bytes encryptedKey)`

Inputs:

- `escrowId`
- `encryptedKey`

Uses:

- caller must be escrow seller
- escrow must be `Pending`
- must be on or before deadline

Writes:

- stores `encryptedKey`
- sets escrow status to `Delivered`
- transfers escrow amount to seller

Important:

- the contract does not verify whether `encryptedKey` is correct for the buyer or the allocated item

### `reclaimEscrow(uint256 escrowId)`

Inputs:

- `escrowId`

Uses:

- caller must be escrow buyer
- escrow must be `Pending`
- deadline must have passed

Writes:

- sets escrow status to `Reclaimed`
- refunds escrow amount to buyer
- inventory is not restored

## Events

- `ProductCreated`
- `ProductItemsAdded`
- `ProductStatusChanged`
- `EscrowCreated`
- `EscrowDelivered`
- `EscrowReclaimed`

## Deployments

### Sonic Testnet

- Chain ID: `14601`
- ZkRevealStore: `0x7f5c1f1D8F0EB3c4eE0fBad239936D2B0BA093f1`
- Tx: `0x8662f52b5b56e020597db48c1930ec243fad46e22708f49d00764c0f1337c36c`
- Block: `12692107`
- Compiler: `0.8.24`
- EVM Version: `paris`

## Development

```bash
forge build
forge fmt --check
forge test --offline
```
