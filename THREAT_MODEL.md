# SophaxChat Threat Model

> Last updated: 2026-04-02
> Version: Sprint 2 (MLS coordinator handoff, Android parity)

---

## 1. What SophaxChat Protects

| Asset | Where stored | How protected |
|---|---|---|
| Long-term identity keys (Ed25519 signing, X25519 DH) | iOS Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | OS-level SEP / Secure Enclave isolation |
| MLS KeyPackage secret key | iOS Keychain (per-group, per-epoch) | Same Keychain policy |
| Message content (1-to-1) | AES-256-GCM encrypted JSON files in Application Support | `FileProtectionType.complete` — inaccessible when device locked |
| Message content (group, SKv2) | AES-256-GCM encrypted JSON files | `FileProtectionType.complete` |
| Message content (group, MLS) | Per-epoch MLS AEAD ciphertext on disk | `FileProtectionType.complete` |
| Attachments (images, audio) | AES-256-GCM in Application Support/sophax_attachments/ | `FileProtectionType.complete` |
| Contact list (peerAliases) | iOS Keychain (migrated from UserDefaults) | Keychain ACL |
| Identity export backup | PBKDF2-SHA256 720,000 iterations + AES-256-GCM, 16-char min passphrase | In-memory key zeroed after use |
| Key transparency log | HMAC-SHA256 append-only log in UserDefaults + MAC key in Keychain | Detects tampering of historical key bindings |

---

## 2. Attacker Model

### In scope

| Attacker | Capability |
|---|---|
| **Passive network observer** | Monitors Bluetooth/WiFi radio; sees encrypted frames, timing, and approximate proximity |
| **Active mesh attacker** | Can inject, replay, or drop mesh (MultipeerConnectivity) frames |
| **Malicious peer** | A SophaxChat peer who has established a session; can send crafted wire messages |
| **Compromised relay node** | A hop in the multihop relay path; can see ciphertext but not plaintext |
| **Server / infrastructure** | There are no servers; not applicable |
| **Physical access — locked device** | Can extract encrypted files from a powered-off or locked device |

### Out of scope

- Nation-state RF analysis or radio fingerprinting
- Physical access to an **unlocked** device (game over for any app)
- OS/kernel compromise or jailbreak
- Supply-chain attacks on the App Store build pipeline
- Legal coercion of the device owner
- Side-channel attacks on Secure Enclave

---

## 3. Attack Surface

### 3.1 Mesh Transport (MultipeerConnectivity)

- **Unauthenticated frames**: Every received frame is verified against the sender's Ed25519 signing key (derived from their bundle's peerID). Frames with invalid signatures are dropped before any parsing.
- **Relay amplification**: TTL=6, LRU dedup cache prevents replay and loops. Relay nodes cannot read ciphertext.
- **Offline queue**: Messages queued for offline peers are stored encrypted; the relay node never holds plaintext.
- **Missing mitigation**: Bluetooth/WiFi proximity leaks that two devices are near each other, regardless of message content. This is inherent to the transport.

### 3.2 TCP Transport (optional, over Tor)

- **Frame size pre-check**: `TCPTransport.maxFrameSize` guard rejects oversized frames before allocation.
- **Tor**: When enabled, routes TCP connections through Tor hidden services — hides IP from the remote peer. Tor is optional; the user can toggle it in Settings.
- **Missing mitigation**: TCP without Tor exposes the user's IP to their peer.

### 3.3 Wire Protocol

- **WireMessage**: Signed with sender's Ed25519 key on every message. Receiver verifies before dispatch.
- **Sealed sender**: Sender identity is encrypted to the recipient's bundle — relay nodes cannot correlate sender ↔ recipient for 1-to-1 messages.
- **Header encryption**: DR-encrypted message headers prevent relay nodes from reading metadata (message type, reply-to ID, etc.).
- **Replay prevention**: Nonce embedded in DR ratchet state; old nonces rejected. MLS epoch counter prevents replaying old Commits.

### 3.4 1-to-1 Messaging (X3DH + Double Ratchet)

- **X3DH**: Extended Triple Diffie-Hellman for session initialization. Provides forward secrecy from message 1.
- **Double Ratchet**: Per-message ratchet (ChaCha20-Poly1305 AEAD). Compromise of one message key does not expose past or future messages.
- **Post-compromise security**: DR break-in recovery after key compromise — new DH output heals the session.
- **Missing mitigation**: If a peer's device is seized while unlocked and a session is active, past plaintext cached in memory may be readable.

### 3.5 Group Messaging — Sender Keys v2 (SKv2)

- **Per-member HMAC-SHA256 chain**: Each sender has their own KDF chain. Compromise of one sender's key does not expose other members' messages.
- **Auto-rotation**: Sender keys rotate every 500 messages or 7 days. After rotation, a compromised old key cannot decrypt new messages.
- **Leave recovery**: When a member leaves, remaining members rotate immediately — the leaver cannot decrypt future messages.
- **Known limitation**: SKv2 provides *break-in recovery* only after rotation. Between join and next rotation, a compromised device has read access to all group messages from all senders (no post-compromise security per epoch). MLS fixes this.
- **Known limitation**: Group membership is enumerable by any member — all member peerIDs are in `GroupInvitePayload` and `GroupWireMessage`.

### 3.6 Group Messaging — MLS (RFC 9420)

- **Post-compromise security per epoch**: Each MLS Commit advances the epoch and derives fresh secrets. A compromised device is healed at the next Commit.
- **Forward secrecy per epoch**: Old epoch secrets are deleted after the Commit. Past messages are not decryptable after key deletion.
- **Coordinator authority**: Only the current coordinator (initially the creator, transferable via handoff) may issue Commits. Non-coordinator members who attempt to commit are rejected.
- **Coordinator handoff**: `mlsCoordinatorHandoff` wire message transfers authority. Only the current coordinator can sign a valid handoff. Recipients verify sender == current coordinator.
- **Known limitation**: The coordinator is a single point of trust for group membership changes. If the coordinator's device is compromised, an attacker can add or remove members without consent. Mitigated by distributing coordinator authority via handoff.
- **Known limitation**: No multi-device support. An MLS group is anchored to a single device's KeyPackage. Adding the same identity on a second device is not yet supported.

### 3.7 Keychain and Local Storage

- **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**: Keys are inaccessible when the device is locked and cannot be migrated off the device (no iCloud Keychain sync for these items).
- **Full account wipe**: `ChatManager.wipeAllData()` deletes all Keychain items, message files, attachments, and UserDefaults.
- **App lock**: Face ID / Touch ID gate via LocalAuthentication. State is cleared in memory on background.
- **Known limitation**: A forensic extraction from a locked (but previously-unlocked) device might recover decrypted pages from the SQLite WAL or AES-GCM plaintext from process memory before the OS evicts it. FileProtection.complete mitigates but does not eliminate this.

### 3.8 Identity Export

- **PBKDF2-SHA256, 720,000 iterations**: Expensive key derivation to resist offline brute-force.
- **16-character minimum passphrase**: Enforced at backup creation time.
- **Memory zeroing**: Derived key bytes are zeroed immediately after use.
- **Known limitation**: An export file stored in iCloud Drive or a photo library is only as secure as the passphrase.

---

## 4. Trust Assumptions

1. **iOS / Android OS**: The OS Keychain and Secure Enclave are not compromised.
2. **App Store build**: The SophaxChat binary in the App Store has not been tampered with.
3. **mls-rs library**: The RFC 9420 implementation is correct and free of side-channel vulnerabilities.
4. **No server**: There is no backend. No third party stores messages or metadata.
5. **Peer identity**: A peer's identity is bound to their Ed25519 key pair. SophaxChat does not verify that a key pair belongs to a specific human — users must verify Safety Numbers out-of-band.

---

## 5. Cryptographic Primitives

| Primitive | Usage |
|---|---|
| Ed25519 | Message signing, identity binding |
| X25519 | X3DH and Double Ratchet DH steps |
| ChaCha20-Poly1305 | AEAD for 1-to-1 and group (SKv2) message encryption |
| HMAC-SHA256 | SKv2 KDF chain ratchet, Key Transparency Log MAC |
| AES-256-GCM | At-rest encryption for messages, attachments, identity export |
| PBKDF2-SHA256 | Identity export key derivation (720,000 iterations) |
| MLS (RFC 9420) | Group v3 — per-epoch PCS, per-epoch forward secrecy |

---

## 6. Known Limitations Summary

| # | Limitation | Severity | Mitigation |
|---|---|---|---|
| 1 | SKv2 groups: no PCS between rotations (max 500 msgs / 7 days) | Medium | Upgrade group to MLS via in-app migration |
| 2 | Group membership enumerable by all members | Low | Acceptable for a group messaging model |
| 3 | MLS coordinator = single point of group admin trust | Medium | Coordinator handoff distributes authority |
| 4 | No multi-device support | Medium | Out of scope for v1; planned for later |
| 5 | Bluetooth/WiFi proximity leak (transport-level) | Low | Inherent to MPC/Nearby Connections; Tor only helps TCP path |
| 6 | TCP without Tor exposes IP to peer | Medium | Tor toggle in Settings; default on |
| 7 | Memory forensics on unlocked/recently-locked device | Medium | App lock clears in-memory state; FileProtection.complete limits disk exposure |
| 8 | No independent security audit | High | Planned before public App Store launch |

---

## 7. Out of Scope

The following are explicitly out of scope for SophaxChat v1:

- **Anonymity network**: SophaxChat hides message content but not proximity. Two users near each other using the app are observable at the RF layer.
- **Deniability**: Messages are signed by the sender's Ed25519 key. This is intentional (integrity guarantee) but means messages are not cryptographically deniable.
- **Key revocation**: There is no mechanism to revoke a compromised long-term identity key. Users should do a full account wipe.
- **Server-assisted features**: No push notifications via APNs (messages require the app open), no contact discovery, no phone number verification.
