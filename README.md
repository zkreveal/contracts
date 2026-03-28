# zkReveal

zkReveal is an on-chain encrypted digital delivery escrow primitive.

It enables sellers to deliver encrypted access (files, credentials, or content) to buyers using time-bound escrow, where delivery is enforced on-chain and decryption happens off-chain.

This repository contains the v0 smart contract implementation built with Foundry and deployed on Arbitrum Sepolia.

zkReveal is a minimal, composable on-chain primitive designed to be integrated into marketplaces, APIs, and off-chain delivery systems.
It focuses purely on enforcement and settlement, leaving validation and UX to integrators.

## Why zkReveal

Most digital commerce today relies on trusted platforms to handle delivery of digital goods.

zkReveal introduces a minimal on-chain primitive for:
- encrypted delivery of digital assets
- time-bound escrow with automatic refund
- composable purchase receipts on-chain

This enables new patterns for:
- private data marketplaces
- API key or credential delivery
- gated content and access systems

## Why Arbitrum

zkReveal benefits from Arbitrum’s:

- low transaction costs for frequent escrow creation
- fast confirmations for buyer-seller interactions
- strong EVM compatibility and tooling
- suitability for building higher-level protocols on top

Arbitrum provides a practical base layer for scaling encrypted delivery primitives into real-world applications.

> ⚠️ **Warning**
> This is a v0 trusted-seller escrow model.  
> The contract enforces delivery timing but does not verify correctness of delivered content.  
> Do not use in production without further validation and auditing.

## System Flow

Seller creates listing
→ Adds inventory units
→ Buyer opens escrow with public key
→ Seller delivers encrypted payload + CID before deadline

Outcome:
- Delivered → seller paid
- Timeout → buyer refunded

This flow ensures that payment is conditional on timely delivery, while keeping content encryption and verification fully off-chain.

## Architecture (v0)

zkReveal uses a hierarchical model:

- `Listing`: reusable sale entry with human-readable `title`, seller-defined `resourceId`, and per-unit price.
- `InventoryUnit`: one inventory unit under a listing; `contentCID` is assigned only when the seller delivers an escrow.
- `Escrow`: one buyer purchase tied to exactly one allocated inventory unit.

Seller identity is defined by the seller’s wallet address.

## Security Model (v0)

This contract is a trusted-seller delivery escrow, not a trustless proof system.

- `deliverEscrow` only verifies that `contentCID` and `encryptedKey` are non-empty and submitted on or before the escrow deadline.
- The contract does not prove that the CID or encrypted payload are correct for the allocated item.
- Seller is paid immediately after successful delivery submission.
- Correctness of the delivered payload is verified off-chain by the buyer.

## On-Chain Visibility

The following data is public on-chain or retrievable from contract state:

- listing `title` and `resourceId`
- delivered `InventoryUnit.contentCID`
- `Escrow.buyerPubKey`
- `Escrow.encryptedKey`
- escrow timestamps, status, seller, buyer, listing id, and inventory unit id

The following data is not stored on-chain:

- plaintext content
- buyer private key
- decrypted symmetric key material

## Core Contract

- `src/ZkRevealStore.sol`

Key storage:

- `listings[listingId]`
- `inventoryUnits[inventoryUnitId]`
- `escrows[escrowId]`
- `listingsBySeller[seller]`
- `listingInventoryUnitIds[listingId]`

Escrow status:

- `Pending`
- `Delivered`
- `Reclaimed`

## Listing Identity

- `listingId` is the canonical protocol-local on-chain identifier.
- `resourceId` is a seller-defined, machine-readable, non-normalized identifier for integrations.
- `resourceId` is not unique and must not be treated as a globally safe identifier by itself.

For off-chain canonical identity, prefer:

- `(chainId, contractAddress, listingId)`

For off-chain semantic identity, prefer:

- `(chainId, contractAddress, seller, resourceId)`

Each escrow can be treated as an on-chain purchase receipt. A delivered escrow is a delivered claim for the listing's semantic resource identity.

## High-Level Flows

### Seller flow

1. Create listing via `createListing(title, resourceId, unitPrice, refundWindow)`.
2. Add inventory units via `addInventoryUnitsToListing(listingId, count)`.
3. Buyer creates escrow via `createEscrow`.
4. Seller submits both `contentCID` and a non-empty encrypted delivery payload via `deliverEscrow(escrowId, contentCID, encryptedKey)`.
5. Contract pays seller immediately on successful delivery submission.

### Buyer flow

1. Generate buyer encryption keypair off-chain.
2. Call `createEscrow(listingId, buyerPubKey)` and pay exact `unitPrice`.
3. Wait for seller delivery; read the public `escrow.encryptedKey` from `getEscrow`.
4. Read the delivered `contentCID` from the allocated inventory unit via `getInventoryUnit(escrow.inventoryUnitId)`.
5. Decrypt content key off-chain and use the delivered `contentCID`.
6. If seller misses deadline, call `reclaimEscrow(escrowId)` to refund.

## Function Interface and Data Use

### `createListing(string title, string resourceId, uint256 unitPrice, uint64 refundWindow)`

Inputs:

- `title`: listing name
- `resourceId`: seller-defined semantic identifier for integrations
- `unitPrice`: price per item
- `refundWindow`: escrow reclaim window

Uses:

- validates non-empty title, non-empty resourceId, non-zero price, and refund window bounds

Writes:

- new `Listing`
- `listingsBySeller[msg.sender]`

### `addInventoryUnitsToListing(uint256 listingId, uint256 count)`

Inputs:

- `listingId`
- `count`: number of inventory units to add

Uses:

- caller must be listing seller
- count must be greater than zero

Writes:

- appends empty `InventoryUnit` rows
- appends to `listingInventoryUnitIds[listingId]`
- increments listing `totalInventoryUnits`

### `setListingActive(uint256 listingId, bool active)`

Inputs:

- `listingId`
- `active`

Uses:

- caller must be listing seller

Writes:

- listing availability flag

### `createEscrow(uint256 listingId, bytes buyerPubKey) payable`

Inputs:

- `listingId`
- `buyerPubKey`
- `msg.value`

Uses:

- listing must be active with available inventory
- `msg.value` must equal listing `unitPrice`
- internally calls `_allocateNextInventoryUnit(listingId)` (sequential allocation)

Writes:

- marks one `InventoryUnit` as `consumed`
- creates `Escrow` with listing/inventory-unit linkage, buyer/seller, amount, key, timestamps, deadline, status

### `deliverEscrow(uint256 escrowId, string contentCID, bytes encryptedKey)`

Inputs:

- `escrowId`
- `contentCID`
- `encryptedKey`

Uses:

- caller must be escrow seller
- escrow must be `Pending`
- `contentCID` must be non-empty
- must be on or before deadline

Writes:

- stores `contentCID` on the allocated `InventoryUnit`
- stores `encryptedKey`
- sets escrow status to `Delivered`
- transfers escrow amount to seller

**Note:**

- the contract does not verify whether `contentCID` or `encryptedKey` are correct for the buyer or the allocated item

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
- inventory units are not restored after reclaim

## Events

- `ListingCreated` includes `resourceId`
- `InventoryUnitAdded`
- `ListingStatusChanged`
- `EscrowCreated` keeps prior fields and appends `resourceId`
- `EscrowDelivered` includes `listingId`, `buyer`, `resourceId`, and `contentCID`
- `EscrowReclaimed` includes `listingId`, `buyer`, and `resourceId`

## Deployments

### Arbitrum Sepolia

- Status: Deployed and live on Arbitrum Sepolia
- Chain ID: 421614
- Contract: 0x80d0943a39B394e8a5B942c25D90bbB097c762bB
- Transaction: https://sepolia.arbiscan.io/tx/0xead9ef1dae770b4ae0c61d31508ebc88dfd9bb8596dc2f1df0a1ce47d1a8200f
- Block: 254067517

### Mainnet
- Planned target: Arbitrum One

## Setup
Environment variables:

```bash
export DEPLOYER_PRIVATE_KEY="0xx"         
export RPC_ARB_SEPOLIA="https://sepolia-rollup.arbitrum.io/rpc"
```

## Development

```bash
forge build
forge fmt --check
forge test
```

## Additional Docs

- `docs/ENCRYPTION_SPEC_V0.md` — encryption and delivery model
- `docs/LOCK_SPEC.md` — escrow lifecycle and state transitions
