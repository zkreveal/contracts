## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

# zkReveal — v0 (Trusted Seller Delivery Escrow)

zkReveal v0 is a minimal, production-minded escrow rail for **encrypted digital delivery**.

- A **seller** lists an **encrypted content CID** (public) + a commitment to the symmetric key (`kHash`).
- A **buyer** pays escrow and provides a public encryption key (only its hash is stored).
- The **seller** must deliver **EK ciphertext** (encrypted `(K || salt)` for the buyer) **on-chain before the deadline** to get paid.
- If the seller does not deliver in time, the **buyer refunds** after the deadline.

This is a **Trusted Seller** design (v0): the contract enforces payment flow + deadlines, but does **not** prove the seller delivered a *correct* key.

---

## Contract

- `ZkRevealStore.sol`
  - Listing → escrow purchase → delivery → payout
  - Deadline-based refund when delivery doesn’t happen

### State machine

- `Listed` → `Paid` → `Committed`
- `Listed` → `Cancelled`
- `Paid` → `Refunded`

Once `Committed/Cancelled/Refunded`, the item is locked.

---

## Public vs private data (v0)

### Stored on-chain

- `contentCID` (string): **public pointer** to the encrypted content blob (e.g. IPFS CID)
- `contentCIDHash`: `keccak256(bytes(contentCID))`
- `kHash`: commitment to the symmetric key: `keccak256(K || salt)`
- `buyerPubKeyHash`: `keccak256(buyerPubKey)`
- `deadline` and `state`
- `ekCiphertext`: encrypted payload for buyer containing `(K || salt)`
- `ekHash` and `deliveryReceiptHash`

### NOT stored on-chain

- plaintext content
- symmetric key `K` or `salt`
- buyer private key

---

## Flow

### Seller (happy path)

1) **Encrypt content off-chain**
   - Generate `K` + `salt`
   - `kHash = keccak256(abi.encodePacked(K, salt))`
   - `contentCipher = Encrypt(contentPlain, K)`
   - Upload `contentCipher` to IPFS → `contentCID`
   - `contentCIDHash = keccak256(bytes(contentCID))`

2) **List**
   - Call `createItem(priceWei, contentCID, contentCIDHash, kHash)`

3) **After buyer pays**, compute delivery payload
   - Read `buyerPubKey` from the buy tx calldata
   - `ekCiphertext = EncryptToBuyerPubKey(buyerPubKey, (K || salt))`

4) **Deliver + get paid**
   - Call `deliver(itemId, buyerPubKey, ekCiphertext)` before `deadline`

### Buyer (happy path)

1) **Generate keypair**
   - Create `buyerPubKey` / `buyerPrivKey`

2) **Buy**
   - Call `buy(itemId, buyerPubKey, refundWindowSeconds)` and pay exact `priceWei`

3) **Wait for delivery**
   - When state becomes `Committed`, read `ekCiphertext` via `getEkCiphertext(itemId)`

4) **Decrypt K and verify**
   - Decrypt `ekCiphertext` with `buyerPrivKey` → obtain `(K, salt)`
   - Verify: `keccak256(abi.encodePacked(K, salt)) == kHash`

5) **Fetch & decrypt content**
   - Fetch encrypted content from `contentCID`
   - Decrypt with `K`

### Refund

- If seller does not deliver by `deadline`, buyer calls `refund(itemId)` after deadline.

---

## Local development (Foundry)

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Format

```bash
forge fmt
```

### Gas snapshot

```bash
forge snapshot
```

---

## Notes

- v0 assumes **trusted sellers** (gateway mode). The contract guarantees:
  - escrow safety
  - delivery-or-refund via deadline
  - on-chain availability of `ekCiphertext`

- Future versions may add stronger guarantees (e.g., proofs / dispute mechanisms / additional commitments), but v0 is intentionally minimal.