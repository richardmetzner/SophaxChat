# Cryptography

Full audit-ready summary: [`docs/CRYPTO_SUMMARY.md`](https://github.com/richardmetzner/SophaxChat/blob/main/docs/CRYPTO_SUMMARY.md)  
Threat model: [`SECURITY.md`](https://github.com/richardmetzner/SophaxChat/blob/main/SECURITY.md)

All primitives are from Apple's **CryptoKit** (audited, hardware-accelerated via Secure Enclave where available). No third-party cryptographic libraries for core operations.

---

## Primitive summary

| Layer | Operation | Algorithm | Key size |
|---|---|---|---|
| Identity signing | Sign / Verify | Ed25519 | 256-bit |
| Key agreement | DH exchange | X25519 | 256-bit |
| Symmetric encryption | AEAD | ChaCha20-Poly1305 | 256-bit |
| At-rest encryption | AEAD | AES-256-GCM | 256-bit |
| Key derivation | KDF | HKDF-SHA256 | — |
| Group ratchet | MAC | HMAC-SHA256 | 256-bit |
| Identity export | KDF | PBKDF2-SHA256 | 720 000 iter |
| Key transparency | MAC | HMAC-SHA256 | 256-bit |

---

## Key types and storage

| Key | Lifetime | Storage | Accessible |
|---|---|---|---|
| Identity Key (IK) — Ed25519 + X25519 | Permanent | Keychain | `WhenUnlockedThisDeviceOnly` |
| Signed Prekey (SPK) | 7 days | Keychain | `WhenUnlockedThisDeviceOnly` |
| One-Time Prekeys (OTPKs × 20) | Single use | Keychain | `WhenUnlockedThisDeviceOnly` |
| Double Ratchet state | Per session | Keychain | `WhenUnlockedThisDeviceOnly` |
| Sender Key chains | Per group member | Keychain | `WhenUnlockedThisDeviceOnly` |
| Message store encryption key | Permanent | Keychain | `WhenUnlockedThisDeviceOnly` |

No key material is ever written to UserDefaults, iCloud, or device backups.

---

## X3DH — session setup

Extended Triple Diffie-Hellman establishes a shared secret between two parties who have never communicated, providing:
- **Forward secrecy** from the first message (OTPK consumed)
- **Cryptographic binding** to both long-term identities

```
SK = HKDF-SHA256(
  DH(IK_sender,  IK_recipient) ‖   // mutual identity binding
  DH(EK_sender,  IK_recipient) ‖   // ephemeral × identity
  DH(EK_sender,  SPK_recipient) ‖  // ephemeral × signed prekey
  DH(EK_sender,  OTPK_recipient)   // ephemeral × one-time prekey
)
```

The ephemeral key `EK_sender` is generated fresh per session and discarded immediately after KDF. The OTPK is consumed and deleted.

---

## Double Ratchet + Header Encryption

After X3DH, all messages use the Double Ratchet Algorithm (Signal spec §3–§4):

### Symmetric ratchet (every message)
```
messageKey  = HMAC-SHA256(chainKey, 0x01)
chainKey    = HMAC-SHA256(chainKey, 0x02)
ciphertext  = ChaCha20-Poly1305(messageKey, plaintext, AD)
```

### DH ratchet (every reply)
A new X25519 ephemeral key pair is generated on each reply, rotating the root key and providing **break-in recovery** (post-compromise security).

### Header Encryption (SophaxChat extension)
Message headers (ratchet public key, sequence numbers) are encrypted with a separate rotating `headerKey` derived during the DH ratchet step. Relay nodes cannot observe:
- Who is speaking to whom (beyond endpoint)
- Sequence numbers / message order
- Ratchet key material

---

## Sealed Sender

Before transmission, every message is wrapped in an additional layer that hides the sender's identity from relay nodes:

```
ephemeralKey  = X25519.generate()
sharedSecret  = HKDF(DH(ephemeralKey, IK_recipient))
sealedOuter   = ChaCha20-Poly1305(sharedSecret, innerMessage ‖ senderID)
wire          = { ephemeralKey.publicKey, sealedOuter }
```

A relay node sees only `ephemeralKey.publicKey` and an opaque ciphertext. Only the intended recipient can unseal the outer layer and learn the sender's identity.

---

## At-rest encryption

| Store | Key derivation | Algorithm |
|---|---|---|
| Message database | Random 256-bit key in Keychain | AES-256-GCM |
| Attachment blobs | Random 256-bit key per file in Keychain | AES-256-GCM |

File protection class: `FileProtectionType.complete` — files are inaccessible while the device is locked, even to the OS.

---

## Identity export / backup

Backup passphrase requirements:
- Minimum **16 characters**
- PBKDF2-SHA256 with **720 000 iterations** (≈ 2× Signal's 2024 default)
- Random 32-byte salt stored with the export

Key material is zeroed from memory immediately after serialisation.

---

## Key Transparency Log

Every identity key change is appended to a local HMAC-SHA256 verified log (append-only, stored in UserDefaults). The HMAC key is stored in Keychain. Tampering with the log (e.g. to erase evidence of a key change) is detectable.

---

## Known limitations

- **No independent security audit** — highest priority before v1.0. See [`SECURITY.md`](https://github.com/richardmetzner/SophaxChat/blob/main/SECURITY.md).
- **No post-quantum cryptography** — X25519 and Ed25519 are classical. Harvest-now-decrypt-later attacks are a long-term concern. MLS (RFC 9420) is designed to support PQC algorithm negotiation in future.
- **Metadata on local network** — BLE/WiFi Direct presence reveals that the app is running to nearby devices. Tor mode eliminates IP-level metadata for TCP connections.
