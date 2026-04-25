# Reveal Protocol

This branch is focused on `RevealReceiptStore`, a receipt-only settlement contract for mainnet deployment.

Sellers create listings with a `title`, `resourceId`, and `unitPrice`. Buyers purchase those listings using seller-issued `purchaseRef` values. Payment settles immediately in the configured ERC-20 settlement token, and the contract records a canonical on-chain receipt for downstream reconciliation.

## Core Contract

- `src/RevealReceiptStore.sol`

Key storage:

- `listings[listingId]`
- `receipts[receiptId]`
- `listingsBySeller[seller]`
- `receiptsByBuyer[buyer]`
- `receiptsBySeller[seller]`
- `purchaseRefUsed[seller][purchaseRef]`
- `receiptIdBySellerAndPurchaseRef[seller][purchaseRef]`

## Receipt Flow

Seller flow:

1. Call `createListing(title, resourceId, unitPrice)`.
2. Optionally pause or resume the listing with `setListingActive(listingId, active)`.
3. Generate a seller-scoped `purchaseRef` off-chain for a buyer order.

Buyer flow:

1. Approve the ERC-20 settlement token to the store.
2. Call `purchaseReceipt(listingId, purchaseRef)`.
3. Read the stored receipt on-chain or index the `ReceiptPurchased` event.

Settlement behavior:

- buyer funds are pulled with `transferFrom`
- protocol fee is computed in-contract from immutable deployment config
- protocol fee is sent to `feeRecipient` when `protocolFeeBps > 0`
- seller receives the remaining settlement amount immediately

## Fee Model

`RevealReceiptStore` no longer depends on a separate `RakeEngine`.

Deployment config is now:

- `settlementToken`
- `feeRecipient`
- `protocolFeeBps`

Constraints:

- `protocolFeeBps` is capped at `1_000` basis points
- `feeRecipient` must be non-zero when `protocolFeeBps > 0`

## Listing Identity

- `listingId` is the canonical on-chain identifier.
- `resourceId` is seller-defined semantic metadata for integrations.
- `purchaseRef` must be unique per seller.

Recommended off-chain identifiers:

- canonical listing identity: `(chainId, contractAddress, listingId)`
- semantic listing identity: `(chainId, contractAddress, seller, resourceId)`
- canonical receipt lookup: `(chainId, contractAddress, seller, purchaseRef)`

## Development

Common commands:

```bash
forge build
forge test
```

## Deployment

The deploy script at `script/Deploy.s.sol` expects these environment variables:

- `DEPLOYER_PRIVATE_KEY`
- `SETTLEMENT_TOKEN`
- `RECEIPT_PROTOCOL_FEE_BPS`
- `TREASURY_MULTISIG` when `RECEIPT_PROTOCOL_FEE_BPS > 0`

The included `.env.example` also contains RPC and Arbiscan placeholders for Arbitrum deployments.
