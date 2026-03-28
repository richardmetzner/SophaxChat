# SophaxChat — Threat Model

> Version 1.0 · 2026-03-28
> Prepared for independent security audit

---

## 1. System Overview

SophaxChat is a serverless, anonymous peer-to-peer encrypted messaging application for iOS and macOS. All communication happens directly between devices over local radio transports. There are no servers, no cloud infrastructure, and no central directories.

```
┌────────────┐    Bluetooth LE / WiFi Direct     ┌────────────┐
│  Device A  │◄─────────────────────────────────►│  Device B  │
│ (Alice)    │                                   │ (Bob)      │
└────────────┘         optionally via            └────────────┘
                  ┌─────────────────────┐
                  │  Relay device (C)   │
                  │  (honest-but-curious│
                  │   mesh node)        │
                  └─────────────────────┘
```

**Transports:**
- MultipeerConnectivity (Apple) — Bluetooth LE + WiFi Direct, up to 6 relay hops (TTL)
- mDNS / TCP — same WiFi network
- Tor hidden services (`.onion`) — optional, for global reachability

**Identity model:** Each user generates a random Ed25519 + X25519 keypair on first launch. There are no usernames registered with any server; the `peerID` is `SHA256(signingPub ∥ dhPub)[:16]`.

---

## 2. Assets Being Protected

| Asset | Sensitivity | Storage |
|-------|-------------|---------|
| Ed25519 signing private key | Critical | iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) |
| X25519 DH private key | Critical | iOS Keychain |
| Double Ratchet session states | High | Keychain (JSON-encoded per peer) |
| Message plaintext | High | AES-256-GCM encrypted files in Application Support |
| Contact list (known peers) | Medium | UserDefaults (contains only public keys + usernames) |
| Attachment files (images, audio, video) | High | AES-256-GCM encrypted files in Application Support |
| Username | Low | Keychain + broadcast in Hello messages |
| Safety numbers (verification state) | Medium | Keychain |
| Group sender key chains | High | Keychain (per-group, per-member) |

---

## 3. Trust Boundaries

```
┌─────────────────────────────────────────────────────┐
│  Trusted: iOS Secure Enclave / Keychain              │
│  Trusted: Swift standard library / CryptoKit        │
├──────────────────────────┬──────────────────────────┤
│  Semi-trusted:            │  Untrusted:              │
│  MultipeerConnectivity   │  Mesh relay nodes        │
│  (Apple framework)       │  Remote peers            │
│                          │  Network (BLE/WiFi air)  │
└──────────────────────────┴──────────────────────────┘
```

**iOS Keychain** is the root of trust. Private keys never leave the Keychain in plaintext and are bound to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (not migratable, not iCloud-backed).

---

## 4. Attacker Models

### 4.1 Passive Observer
**Capability:** Can observe all Bluetooth/WiFi frames in radio range.
**Cannot:** Decrypt any messages; all payloads are ChaCha20-Poly1305 encrypted.
**Learns:** Approximate location of communicating devices (radio proximity), packet timing, approximate message sizes (padded), and sender/recipient peerIDs in relay headers.
**Mitigations:** Sealed sender (peerID encrypted inside DR payload), TTL-limited relay headers, no persistent identifiers in headers.

### 4.2 Active MITM
**Capability:** Can inject, replay, or drop packets on the transport layer.
**Cannot:** Forge authenticated messages; Ed25519 signatures cover every wire message.
**Attacks attempted:** Replay, message injection, route hijacking.
**Mitigations:** HMAC-SHA256 MAC on every message, Double Ratchet nonce prevents replay within a session, message deduplication (LRU cache of seen messageIDs), TTL enforcement.

### 4.3 Malicious Relay Node
**Capability:** Owns a device that participates in mesh routing. Sees all relayed wire messages.
**Cannot:** Decrypt message contents (E2EE); forge messages (signing); identify sender (sealed sender).
**Learns:** Approximate timing and size of relayed messages; public peerIDs in outer relay header (if not sealed).
**Mitigations:** Relay nodes see only outer WireMessage envelope. Inner `MessageContent` is DR-encrypted. Sealed sender wraps the peerID in an ECIES envelope visible only to the recipient.

### 4.4 Compromised Group Member
**Capability:** Attacker owns one member's device and reads their Keychain.
**Past messages:** Protected by forward secrecy — DR ratchet steps ensure past message keys are deleted after use.
**Future messages:** Compromised member's sender key chain is leaked. **Mitigation:** Other members can call "Reset Encryption Key" which generates new sender key chains and distributes them. On member leave, remaining members rotate all their sender keys automatically.
**Group membership:** Compromised member knows the group member list.

### 4.5 Server-Level Attacker
**Capability:** N/A — SophaxChat has no servers.
**Notes:** No metadata is stored server-side. There are no DNS lookups, push notification servers, or CDNs involved in message delivery.

### 4.6 Physical Device Access (Out of Scope for This Audit)
An attacker with physical access to an unlocked device can read all data. This is mitigated by:
- App Lock (Face ID / Touch ID) on foreground restore
- Keychain accessibility flag (`WhenUnlockedThisDeviceOnly`)

Full disk encryption (FileVault / iOS data protection) is handled by the OS and is out of scope.

---

## 5. Threats & Mitigations

| Threat | Attack | Mitigation | Status |
|--------|--------|------------|--------|
| Message eavesdropping | Passive radio sniffing | ChaCha20-Poly1305 AEAD on all messages | ✅ |
| Message forgery | Inject fake messages | Ed25519 signature on every WireMessage | ✅ |
| Replay attack | Re-send captured valid message | DR nonce uniqueness; LRU dedup cache (messageID) | ✅ |
| MITM at session init | Replace X3DH public keys | Safety Numbers (SHA512 fingerprint), user verification | ✅ |
| Identity spoofing | Claim another user's peerID | peerID is SHA256 of public keys; signing verifies control of key | ✅ |
| Sender identification via relay | Relay node identifies sender | Sealed sender: senderPeerID encrypted in ECIES envelope | ✅ |
| Future secrecy loss after compromise | Read future messages | Double Ratchet ratchet step on each message | ✅ |
| Past messages after key compromise | Read past messages | Forward secrecy: DR ratchet deletes used message keys | ✅ |
| Group member eavesdropping after leave | Ex-member reads future | Remaining members rotate sender keys on leave (SKD re-distribution) | ✅ |
| Group MITM via new member | Inject attacker as member | Group invites sent via E2EE DR channel (not broadcast) | ✅ |
| Timing analysis | Infer activity from packet timing | No specific mitigation (out of scope) | ⚠️ |
| Traffic analysis (message size) | Infer content type from size | No padding currently implemented | ⚠️ |
| Prekey exhaustion DoS | Download all OPKs | Prekey rotation, fallback to SPK-only session (with alert) | ✅ |
| Malicious expiry timestamp | Set expiresAt to year 9999 | Clamped to maxExpiryInterval = 1 year | ✅ |
| Oversized message DoS | Send multi-MB body | Message size limit enforced on receive | ✅ |
| Timestamp skew attack | Replay with future timestamp | Timestamp validation window (±10 min) | ✅ |
| Rate-limit bypass | Flood a peer with messages | Per-peer rate limiter in ChatManager | ✅ |
| Session init dedup race | Trigger two X3DH sessions simultaneously | Session initiation dedup (`pendingSessionInits` set) | ✅ |
| Key history tampering | Rewrite UserDefaults keylog | Log is append-only; key changes trigger visible alerts | ✅ |

**⚠️ Known limitations (not mitigated):**
- Traffic analysis via packet sizes and timing
- No message padding (size reveals content type)
- Bluetooth/WiFi presence reveals physical proximity

---

## 6. Cryptographic Parameters Summary

| Primitive | Usage | Key size |
|-----------|-------|----------|
| Ed25519 (CryptoKit) | Identity signing, message authentication | 32B private / 32B public |
| X25519 (CryptoKit) | DH key agreement (X3DH, DR) | 32B private / 32B public |
| ChaCha20-Poly1305 (CryptoKit) | Message encryption (DR) | 32B symmetric key |
| AES-256-GCM (CryptoKit) | Message storage at rest, backup | 32B symmetric key |
| HKDF-SHA256 (CryptoKit) | Key derivation (X3DH, DR chain) | — |
| HMAC-SHA256 | Sender key ratchet (KDF chain) | 32B |
| SHA512 | Safety number fingerprint | — |
| SHA256 | peerID derivation, key log fingerprint | — |
| PBKDF2-HMAC-SHA256 | Backup key derivation | 32B salt, 600 000 iterations |

---

## 7. Out of Scope

- iOS operating system and kernel security
- Bluetooth and WiFi firmware
- MultipeerConnectivity Apple framework internals
- Physical device theft / shoulder surfing
- Side-channel attacks on CryptoKit implementations
- Social engineering / phishing

---

## 8. Recommended Audit Focus Areas

1. **X3DH implementation** (`Sources/SophaxChatCore/Crypto/X3DH.swift`) — key derivation, DH concatenation order, associated data
2. **Double Ratchet** (`Sources/SophaxChatCore/Crypto/DoubleRatchet.swift`) — header encryption, out-of-order handling, skipped key cache
3. **Sealed sender** (`ChatManager.swift` — `sealMessage`/`unsealMessage`) — ECIES envelope, key derivation info
4. **Sender Keys v2** (`ChatManager.swift`, `GroupTypes.swift`) — KDF chain, replay protection, member leave re-keying
5. **Backup encryption** (`BackupManager.swift`) — PBKDF2 parameters, authenticated encryption
6. **Identity export** (`IdentityExport.swift`) — private key handling, passphrase entropy enforcement
7. **Key storage** (`KeychainManager.swift`) — accessibility flags, no data leaving device
8. **Prekey rotation & reuse** (`PreKeyManager.swift`) — OPK consumption, fallback to SPK
