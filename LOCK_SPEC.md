# ZkRevealStore v0 Lock Spec (Trusted Seller Gateway)

This file locks the expected v0 behavior for escrow, delivery, refund, and events.

## Lifecycle

Allowed transitions only:

- `Listed -> Paid -> Committed`
- `Listed -> Cancelled`
- `Paid -> Refunded`

No other transitions are valid. Once `Committed`, `Refunded`, or `Cancelled`, the item is terminal.

## Access Control

- `cancelItem` is seller-only.
- `deliver` is seller-only.
- `refund` is buyer-only.
- No admin override exists.

## Payment Rules

- `buy` requires `msg.value == priceWei`.
- Funds stay escrowed until one of:
  - seller `deliver` before deadline -> seller paid
  - buyer `refund` after deadline -> buyer paid
- State changes occur before external value transfers.
- `deliver` and `refund` are `nonReentrant`.

## Refund Window Bounds

- `MIN_REFUND_WINDOW` and `MAX_REFUND_WINDOW` are enforced in `buy`.

## Delivery Semantics

- `deliver` requires:
  - `state == Paid`
  - before deadline
  - `keccak256(buyerPubKey) == buyerPubKeyHash`
  - non-empty `ekCiphertext`
- `deliver` stores:
  - `ekCiphertext`
  - `ekHash = keccak256(ekCiphertext)`
  - `deliveryReceiptHash = keccak256(abi.encode(itemId, buyer, buyerPubKeyHash, ekCiphertext))`
- On success:
  - `state = Committed`
  - seller is paid immediately

## Listing Commitments

`createItem(priceWei, encUriPointer, encUriPointerHash, ciphertextHash, kHash)` requires:

- non-zero `priceWei`
- non-empty `encUriPointer`
- non-zero `encUriPointerHash`
- `keccak256(bytes(encUriPointer)) == encUriPointerHash`
- non-zero `ciphertextHash`
- non-zero `kHash`

## Locked Event Signatures

- `ItemCreated(itemId, seller, priceWei, encUriPointerHash, ciphertextHash, kHash)`
- `ItemBought(itemId, buyer, priceWei, deadline, buyerPubKeyHash)`
- `ItemDelivered(itemId, ekHash, deliveryReceiptHash)`
- `ItemRefunded(itemId, buyer, amountWei)`
- `ItemCancelled(itemId)`
