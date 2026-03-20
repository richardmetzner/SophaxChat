# SophaxChat Cryptography

SophaxChat implements the same cryptographic protocols as Signal, adapted for a fully serverless P2P mesh.

## Key Material

Each identity consists of two keypairs:

| Key | Algorithm | Purpose |
|-----|-----------|---------|
| Identity signing key | Ed25519 | Signs all WireMessages |
| Identity DH key | X25519 | X3DH + Sealed Sender ECDH |
| Signed prekey | X25519 | X3DH |
| One-time prekeys | X25519 | X3DH (consumed once) |

All keys are stored in the iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Never exported, never backed up.

---

## X3DH (Extended Triple Diffie-Hellman)

Used to establish a shared secret between Alice and Bob without a server.

**Alice (sender) computes:**
```
EK_A = random X25519 keypair

DH1 = ECDH(IK_A,  SPK_B)   // Alice identity × Bob signed prekey
DH2 = ECDH(EK_A,  IK_B)    // Alice ephemeral × Bob identity
DH3 = ECDH(EK_A,  SPK_B)   // Alice ephemeral × Bob signed prekey
DH4 = ECDH(EK_A,  OPK_B)   // Alice ephemeral × Bob one-time prekey (if available)

masterSecret = HKDF-SHA256(0x00…(32B) || DH1 || DH2 || DH3 [|| DH4],
                           salt=0x00…(32B),
                           info="SophaxChat_X3DH_v1",
                           len=64)

rootKey        = masterSecret[0:32]
chainKey       = masterSecret[32:64]
```

**Bob (receiver) computes the same DH values** using his private keys and Alice's public keys from `InitiateSessionMessage`. Both derive identical `rootKey` and `chainKey`.

**Forward secrecy**: Alice's ephemeral key `EK_A` is discarded after use. If an attacker later compromises long-term keys, past sessions remain secure.

---

## Double Ratchet

After X3DH, both parties run the Double Ratchet to derive per-message keys.

### Ratchet Header (in every message)

```json
{
  "dhPublicKey":          "<base64 X25519 32B>",
  "previousChainLength":  0,
  "messageNumber":        0
}
```

### KDF Chains

**Root ratchet** (on each DH ratchet step):
```
rootKey, chainKey = HKDF-SHA256(rootKey || ECDH(myDH, theirDH),
                                info="SophaxChat_RootRatchet_v1",
                                len=64)
```

**Sending/receiving chain** (on each message):
```
messageKey, nextChainKey = HKDF-SHA256(chainKey,
                                       info="SophaxChat_ChainRatchet_v1",
                                       len=64)
```

### Message Encryption

```
nonce = random 12 bytes
ciphertext = ChaCha20-Poly1305(key=messageKey, nonce=nonce, plaintext=JSON(MessageContent))
wire = nonce || ciphertext || tag(16B)
```

**Out-of-order delivery**: skipped message keys are cached (max 1000 per session) until the out-of-order message arrives.

---

## Group Messaging — Sender Keys (v2)

Each group member maintains a KDF chain per sender.

### Key Distribution

When a member joins or after a membership change, the member sends a `senderKeyDistribution` message (encrypted via Double Ratchet) to all other members:

```json
{
  "groupID":    "UUID",
  "senderID":   "alice_peerID",
  "chainKey":   "<base64 32B>",
  "iteration":  0
}
```

### Per-Message Key Derivation

```
message_key  = HKDF-SHA256(chain_key, info="SophaxChat_SenderKey_Message_v1", len=32)
next_chain   = HKDF-SHA256(chain_key, info="SophaxChat_SenderKey_Chain_v1",   len=32)
```

Iteration counter is included in every `GroupWireMessage` so receivers can fast-forward their chain if they missed messages (up to ±100 iterations tolerance).

### Group Message Encryption

```
nonce      = random 12 bytes
ciphertext = ChaCha20-Poly1305(key=message_key, nonce=nonce, plaintext=messageBody.utf8)
wire       = nonce || ciphertext || tag(16B)
```

### Key Rotation

When a member leaves (`groupMemberLeft`), remaining members generate new chain keys and redistribute via `senderKeyDistribution`. The leaver cannot decrypt future messages.

---

## Sealed Sender

Prevents relay nodes from learning who is messaging whom.

```
EK_s          = random X25519 keypair (ephemeral, per message)
sharedSecret  = ECDH(EK_s.private, recipient.dhIdentityKeyPublic)
sealingKey    = HKDF-SHA256(sharedSecret,
                            info="SophaxChat_SealedSender_v1",
                            len=32)
nonce         = random 12 bytes
ciphertext    = ChaCha20-Poly1305(sealingKey, nonce, JSON(innerWireMessage))
```

Wire payload: `ephemeralPublicKey(32B) || nonce(12B) || ciphertext || tag(16B)`.

---

## Tor v3 .onion Address Derivation

The app derives a stable .onion hostname from the Ed25519 identity signing key (no separate Tor key needed):

```
pubkey    = ed25519_signing_key_public  // 32 bytes
checksum  = SHA3-256(".onion checksum" || pubkey || 0x03)[0:2]
address   = BASE32(pubkey || checksum || 0x03) + ".onion"
```

This is Tor v3 SPEC (proposal 224). The address is deterministic — same identity key always produces the same .onion address.

---

## Safety Number

Used for out-of-band identity verification (equivalent to Signal's safety number):

```
safetyNumber = hex(SHA-256(mySigningKey || theirSigningKey || myDHKey || theirDHKey))
               formatted as 12 groups of 5 digits
```

Displayed in `IdentityView` and as a QR code for scanning.

---

## Implementation Notes

- All crypto uses Apple **CryptoKit** (iOS/macOS) — hardware-backed on devices with Secure Enclave.
- **ChaCha20-Poly1305** is preferred over AES-GCM for its resistance to timing attacks and nonce-misuse.
- Message keys are **erased from memory** immediately after use (Swift `withUnsafeMutableBytes` zero-fill).
- Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — keys cannot leave the device.
