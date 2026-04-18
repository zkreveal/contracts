# Reveal Protocol Encryption Spec v0

## Status

Draft v0 for Reveal Protocol encrypted digital delivery.

This document locks the canonical v0 wire format used at the contract boundary.

---

## 1. Purpose

Reveal Protocol v0 defines a minimal encryption and delivery standard for encrypted digital goods sold through time-bound escrow.

The goals are:

- keep the actual payload offchain
- keep onchain delivery small
- ensure only the intended buyer can decrypt
- keep the seller flow practical for v0
- leave room for stronger commitment or proof-based delivery in future versions

This spec is intentionally simple and implementation-friendly.

---

## 2. High-Level Model

Reveal Protocol uses **envelope encryption**.

Instead of encrypting the payload directly with the buyer’s public key, the seller:

1. generates a random symmetric content key
2. encrypts the payload with that content key
3. uploads the encrypted payload offchain
4. later encrypts the content key for the buyer
5. submits the buyer-encrypted content key onchain during delivery

So:

- **offchain** = encrypted payload
- **onchain** = encrypted content key

---

## 3. Actors

### Seller

Owns the digital good and prepares encrypted inventory.

### Buyer

Provides a public encryption key during purchase and later decrypts the delivered content.

### RevealDeliveryStore Contract

The `RevealDeliveryStore` contract stores escrow state and buyer-specific encrypted delivery material. It does not decrypt or inspect the payload.

---

## 4. Terminology

For clarity in this spec:

- `buyerEncryptionPubKey` refers to the buyer public key as represented in app-layer JSON, HTTP, or other offchain transport
- `buyerPubKey` refers to the raw 32-byte public key passed to the contract
- `contentCID` refers to the offchain content-addressed reference that must point to the encrypted payload envelope defined in Section 7.2, never plaintext content

---

## 5. Cryptographic Structure

### 5.1 Payload Encryption

The seller encrypts the plaintext payload using a randomly generated symmetric key:

- `contentKey`: exactly 32 bytes from a cryptographically secure random source
- `payloadNonce`: exactly 24 bytes from a cryptographically secure random source

Canonical payload cipher for v0:

- **XChaCha20-Poly1305**

Canonical v0 payload-encryption rules:

- no associated data (AAD) is used
- the payload envelope must follow the format defined in Section 7.2

Reasons:

- modern
- safe
- easy to use in JS/backend libraries
- good for arbitrary payload sizes

### 5.2 Key Encryption

The seller encrypts the symmetric `contentKey` using the buyer's public encryption key.

Canonical buyer key type for v0:

- **X25519 public key**

Canonical wrapping scheme for v0:

- **libsodium sealed box: `crypto_box_seal`**

Normative interpretation:

- the buyer public key is exactly 32 raw X25519 public-key bytes
- the seller wraps the 32-byte `contentKey` with `crypto_box_seal(contentKey, buyerPubKey32)`
- the resulting `encryptedContentKey` is stored onchain as raw bytes
- conforming implementations must use libsodium or a byte-for-byte compatible implementation

This removes ambiguity about KDF choice, nonce handling, ephemeral key encoding, and ciphertext layout.

---

## 6. Canonical v0 Flow

### 6.1 Inventory Preparation by Seller

For each inventory unit, the seller:

1. prepares plaintext payload
2. generates random `contentKey`
3. encrypts payload with `contentKey`
4. uploads encrypted payload envelope to IPFS or another content-addressed store
5. obtains `contentCID`
6. stores `{ contentCID, contentKey }` in seller-controlled offchain storage associated with that inventory unit

**Important:**  
The seller must retain the plaintext `contentKey` until the inventory unit is sold and delivered.

Normative requirement:

- `contentCID` must reference the encrypted payload envelope defined in Section 7.2, never plaintext content

In the current v0 contract model, `contentCID` is not written onchain at listing or inventory creation time. It is assigned to the allocated `InventoryUnit` only inside `deliverEscrow(...)`.

### 6.2 Purchase by Buyer

When purchasing delivery, the buyer submits:

- `buyerEncryptionPubKey`

This key is used only for decrypting delivery material.

It should be treated as distinct from the buyer’s wallet signing key unless the implementation explicitly derives both from one wallet-based system.

Protocol requirement at the contract boundary:

- `buyerPubKey` passed to `purchaseDelivery(...)` must be exactly 32 raw X25519 public-key bytes
- base64 is acceptable only in JSON or HTTP transport before contract submission
- app-layer code must decode and validate the key before calling the contract

### 6.3 Delivery by Seller

When the seller delivers an escrow:

1. reads the buyer’s encryption public key from escrow data
2. loads the allocated inventory unit's stored `contentCID` and `contentKey`
3. wraps `contentKey` with `crypto_box_seal`
4. submits both `contentCID` and the resulting `encryptedContentKey` onchain

### 6.4 Decryption by Buyer

The buyer:

1. fetches encrypted payload envelope from `contentCID`
2. fetches `encryptedContentKey` from escrow delivery data
3. decrypts `encryptedContentKey` using their private key
4. recovers `contentKey`
5. decrypts the payload envelope
6. recovers plaintext

If `crypto_box_seal_open(...)` fails, the delivery material must be treated as undecryptable and therefore invalid for the buyer.

---

## 7. Data Formats

### 7.1 Plaintext Payload

Plaintext payload is application-defined bytes.

Examples:

#### Example A — Plain Text Secret

```text
ABC-DEF-123
```

#### Example B — Structured JSON Secret

```json
{
  "type": "gift_card",
  "value": "ABC-DEF-123",
  "issuer": "Example Service",
  "note": "Redeem within 24 hours"
}
```

For protocol purposes, plaintext is just bytes.

### 7.2 Encrypted Payload Envelope

This object is stored offchain and referenced by `contentCID`.

#### Canonical v0 Envelope

```json
{
  "version": "reveal-v0",
  "cipher": "XCHACHA20-POLY1305",
  "nonce": "<base64>",
  "ciphertext": "<base64>",
  "contentType": "text/plain"
}
```

#### Fields

- `version`: must be `"reveal-v0"`
- `cipher`: must be `"XCHACHA20-POLY1305"` in v0
- `nonce`: base64-encoded 24-byte nonce used for payload encryption
- `ciphertext`: base64-encoded encrypted payload bytes
- `contentType`: optional MIME-like hint such as `text/plain` or `application/json`

#### Notes

- no AAD is used in v0
- authentication data is carried inside the AEAD output included in `ciphertext`
- the outer JSON shape is stable for v0
- future versions may add extra metadata fields under a new `version`

### 7.3 Buyer Purchase Input

App-layer JSON example:

```json
{
  "buyerEncryptionPubKey": "<base64-x25519-public-key>"
}
```

#### Field

- `buyerEncryptionPubKey`: buyer's X25519 public key encoded as base64 for transport

Canonical onchain encoding:

- `buyerPubKey` in `purchaseDelivery(listingId, buyerPubKey)` is exactly 32 raw bytes
- callers must not send base64 text bytes to the contract
- because the v0 contract only checks `buyerPubKey.length > 0`, compliant apps must enforce the 32-byte rule offchain

### 7.4 Seller Delivery Payload

App-layer JSON example:

```json
{
  "encryptedContentKey": "<base64-libsodium-sealed-box-bytes>"
}
```

Canonical onchain encoding:

- `bytes encryptedContentKey`
- this value is exactly the raw output of `crypto_box_seal(contentKey, buyerPubKey32)`
- for a 32-byte `contentKey`, the sealed-box output is 80 bytes
- callers may hex-encode or base64-encode this value only for offchain transport; the contract input must be raw bytes

No separate onchain `version` or `scheme` field is used in v0 because the wrapping scheme is fixed canonically by this spec.

---

## 8. Recommended Contract-Level Interpretation

For v0, contract delivery stays very small.

Example logical structure:

```solidity
struct EscrowDelivery {
    bytes encryptedContentKey;
}
```

Canonical interpretation:

- `encryptedContentKey` is the raw sealed-box output described in Section 7.4
- `buyerPubKey` in escrow state is exactly 32 raw X25519 public-key bytes
- the contract records bytes only and does not parse or validate the cryptographic structure

The contract does not need to know:

- payload encryption algorithm internals
- plaintext format
- payload contents
- CID file structure beyond whatever hash/reference is stored elsewhere

At delivery time, the contract only needs to record the delivered `contentCID` plus the buyer-specific encrypted key blob.

---

## 9. Required Seller Behavior

A conforming Reveal Protocol v0 seller implementation must:

1. generate a fresh random `contentKey` per inventory unit
2. encrypt the payload before upload
3. never upload plaintext payload to public storage
4. retain the plaintext `contentKey` securely offchain
5. validate that the buyer-submitted `buyerPubKey` is exactly 32 raw bytes before attempting delivery
6. encrypt `contentKey` with `crypto_box_seal` specifically to the buyer’s submitted public key during delivery
7. submit only buyer-specific encrypted delivery material onchain
8. submit the offchain-stored `contentCID` onchain only at `deliverEscrow(...)`

---

## 10. Required Buyer Behavior

A conforming Reveal Protocol v0 buyer implementation must:

1. generate or provide a valid encryption keypair
2. submit the public encryption key during purchase
3. retain the private key securely
4. use the private key to recover `contentKey`
5. use recovered `contentKey` to decrypt the payload envelope

Additional v0 requirement:

- the contract-facing public key must be exactly 32 raw X25519 public-key bytes

---

## 11. Key Lifecycle

### 11.1 Seller Content Key Lifecycle

For each inventory unit:

- generate once during item preparation
- store offchain until sale
- reuse for that specific inventory unit’s payload
- wrap per buyer upon delivery

This means:

- payload is encrypted once
- content key is wrapped separately for each buyer

That is exactly what you want in v0.

### 11.2 Buyer Key Lifecycle

Buyer encryption keypair may be:

- generated per purchase
- generated per app account
- generated per device
- derived through a wallet-compatible app-layer method

For v0, simplest path is:

- app generates one encryption keypair for the user
- public key is attached to each purchase
- private key remains local to the user/app

---

## 12. Security Properties

This design gives the following properties:

### Confidential Offchain Storage

Anyone can fetch the CID, but cannot decrypt the payload without `contentKey`.

### Buyer-Specific Delivery

Even if another party sees the onchain delivery blob, they cannot use it without the buyer’s private key.

### Small Onchain Delivery Cost

Only encrypted key material is posted onchain.

### Clear Protocol Boundary

The contract manages escrow state; encryption/decryption remain offchain.

---

## 13. Non-Goals for v0

Reveal Protocol v0 does **not** try to solve:

- cryptographic proof that seller payload matches a prior commitment
- zero-knowledge correctness proofs
- proxy re-encryption
- threshold delivery
- buyer anonymity beyond normal chain/privacy assumptions
- seller inability to retain copies of sold goods
- generalized content authenticity proofs

Those can come in later versions.

---

## 14. Important Limitations in v0

### 14.1 Seller Custody of `contentKey`

The seller must keep `contentKey` safely offchain.

If the seller loses it:

- they cannot deliver
- buyer may need to reclaim after timeout

This is acceptable in v0.

### 14.2 No Built-In Commitment Proof

In v0, the buyer learns whether the seller was honest mainly by successful decryption and the usefulness of the decrypted content.

There is no strong cryptographic guarantee yet that the seller committed to a specific valid secret before sale.

That is a later upgrade path.

### 14.3 Public Metadata Leakage

Even though payload is encrypted, some metadata may still leak if not carefully handled:

- item title
- item category
- content type
- CID existence
- timing of delivery

So sellers should avoid placing sensitive information in plaintext metadata.

---

## 15. Implementation Recommendations

### 15.1 Frontend / App UX

Best v0 UX for sellers:

- paste secret into app
- app generates random content key
- app encrypts payload locally
- app uploads encrypted envelope to IPFS
- app stores `{ inventoryUnitId -> { contentCID, contentKey } }` in local secure storage or seller backend
- at delivery time app wraps content key to buyer pubkey with `crypto_box_seal`
- app sends wrapped key onchain
- app sends the stored `contentCID` onchain only during `deliverEscrow(...)`

Best v0 UX for buyers:

- app generates encryption keypair locally
- app stores private key securely
- app includes public key in purchase flow
- app fetches delivery and decrypts automatically

### 15.2 Storage Recommendation

For v0, seller-side secure storage options:

- backend database with encryption at rest
- secure local encrypted file
- secure browser/app vault
- seller-managed keystore

Do not rely on raw clipboard/manual handling for anything serious.

### 15.3 Encoding Recommendation

Use:

- base64 for JSON envelope fields
- raw bytes for contract calls
- hex or base64 only for offchain transport and debugging
- explicit version string in offchain payload

---

## 16. Suggested TypeScript Domain Model

```ts
type EncryptedPayloadEnvelopeV0 = {
  version: "reveal-v0";
  cipher: "XCHACHA20-POLY1305";
  nonce: string;        // base64
  ciphertext: string;   // base64
  contentType?: string;
};

type PurchaseEncryptionInput = {
  buyerEncryptionPubKey: string; // base64 X25519 pubkey for HTTP/JSON transport
};

type DeliveryPayloadV0 = {
  encryptedContentKey: string; // hex or base64 depending on transport
};

type ContractCreateEscrowInput = {
  buyerPubKey: Uint8Array; // exactly 32 raw X25519 pubkey bytes
};

type ContractDeliveryInput = {
  encryptedContentKey: Uint8Array; // raw crypto_box_seal output
};
```

---

## 17. Suggested Seller-Side Pseudocode

```ts
const plaintext = utf8ToBytes(secretValue);
const contentKey = randomBytes(32);
const payloadNonce = randomBytes(24);

const ciphertext = encryptXChaCha20Poly1305(
  plaintext,
  payloadNonce,
  contentKey
);

const envelope = {
  version: "reveal-v0",
  cipher: "XCHACHA20-POLY1305",
  nonce: toBase64(payloadNonce),
  ciphertext: toBase64(ciphertext),
  contentType: "text/plain"
};

// upload envelope -> contentCID
// store { inventoryUnitId -> { contentCID, contentKey } } securely offchain
```

---

## 18. Suggested Delivery Pseudocode

```ts
const buyerPubKey = escrow.buyerPubKey; // raw 32 bytes from contract state
assert(buyerPubKey.length === 32);

const { contentCID, contentKey } = loadSellerStoredInventoryMaterial(
  escrow.inventoryUnitId
);

const encryptedContentKey = crypto_box_seal(
  contentKey,
  buyerPubKey
);

// send contentCID and encryptedContentKey onchain via deliverEscrow(...)
```

---

## 19. Suggested Buyer-Side Pseudocode

```ts
const escrow = fetchEscrow(escrowId);
const inventoryUnit = fetchInventoryUnit(escrow.inventoryUnitId);
const contentCID = inventoryUnit.contentCID;
const envelope = fetchEnvelopeFromCID(contentCID);
const encryptedContentKey = fetchEncryptedContentKeyFromEscrow(escrowId);

const contentKey = crypto_box_seal_open(
  encryptedContentKey,
  buyerPublicKey,
  buyerPrivateKey
);

if (!contentKey) {
  throw new Error("Invalid or undecryptable delivery material");
}

const plaintext = decryptXChaCha20Poly1305(
  fromBase64(envelope.ciphertext),
  fromBase64(envelope.nonce),
  contentKey
);
```

---

## 20. Why This Design

This v0 design is strong because it gives Reveal Protocol a clean and credible minimum architecture:

- payload stays offchain
- delivery stays lightweight
- access is buyer-specific
- contract complexity stays low
- app and backend implementations remain practical
- future commitment and zk upgrades remain possible

It is a good protocol minimum, not just a quick hack.

---

## 21. Future Upgrade Path

This v0 design upgrades cleanly later to:

- committed inventory items
- content hash commitments
- seller attestations
- zero-knowledge proof of format / membership / validity
- proxy re-encryption
- threshold release / oracle release
- encrypted metadata and private listings
- proof of correct delivery semantics

So this is a very good minimum foundation.

---

## 22. Opinionated Canonical Defaults for Reveal Protocol v0

If Reveal Protocol wants one canonical choice with no ambiguity, lock these defaults:

- buyer key type: **X25519**
- payload cipher: **XChaCha20-Poly1305**
- key wrap scheme: **libsodium `crypto_box_seal`**
- payload storage: **IPFS / CID**
- buyer key onchain: **32 raw bytes**
- delivery onchain: **raw sealed-box bytes**
- envelope format: **versioned JSON**
- plaintext payload: **arbitrary bytes**
- seller responsibility: **store `{ contentCID, contentKey }` offchain until delivery**

These defaults make Reveal Protocol v0 feel clean, serious, and protocol-grade.

---

## 23. One-Line Summary

**Reveal Protocol v0 uses envelope encryption: the seller encrypts the payload once offchain with a random symmetric key, then wraps that key with libsodium `crypto_box_seal` for the buyer and delivers the raw wrapped bytes onchain alongside the `contentCID`.**
