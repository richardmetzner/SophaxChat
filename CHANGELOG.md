# Changelog

All notable changes to SophaxChat are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- MLS (RFC 9420) is the default for new groups on iPhone, iPad and Mac when every member has exchanged MLS keys; otherwise the group falls back to Sender Keys v2. Android groups use Sender Keys v2 only.

### In progress
- Group delete (only leave exists today)
- Demo GIF / screen recording for README
- Independent third-party security audit

---

## [0.1.0-alpha] — 2026-04-01

First tagged release. The cryptographic core is complete and has passed three internal security audits. The app is functional but not yet production-ready — an independent audit has not been conducted.

### Cryptography & Protocol
- X3DH (Extended Triple Diffie-Hellman) session establishment — Signal spec
- Double Ratchet with Header Encryption — per-message forward secrecy + relay metadata hiding
- Sealed sender — sender identity hidden from relay nodes via ephemeral ECDH wrapping
- Ed25519 identity signatures on every message
- ChaCha20-Poly1305 AEAD for all symmetric encryption
- AES-256-GCM at-rest storage (messages + attachments)
- Group messaging — Signal-style Sender Keys v2 (per-member HMAC-SHA256 KDF chains)
- **MLS (RFC 9420)** group encryption via mls-rs 0.54 + UniFFI Swift bindings — per-epoch post-compromise security, RustCrypto backend, P2P coordinator pattern
- Safety Numbers — SHA-512 60-digit fingerprint, QR scan + manual verification
- TOFU key-change detection — "Safety Number changed" warning banner
- Identity export / backup — PBKDF2 720 000 iterations, min 16-char passphrase, memory zeroing
- Key Transparency Log — HMAC-SHA256 verified append-only log in UserDefaults

### Transport
- Bluetooth LE + WiFi Direct mesh via MultipeerConnectivity (iOS)
- TCP internet transport — 4-byte length-prefix framing, SOCKS5/Tor proxy support, port 25519
- Tor anonymity — Tor v3 `.onion` address derived from Ed25519 identity key; Orbot auto-detection
- Multihop relay — TTL=6 flood routing with LRU deduplication
- Store-and-forward via relay peers — 48 h TTL, up to 300 items
- Rate limiting — 20 relays / 10 s per peer, 50 / 10 s global cap
- LAN auto-discovery via mDNS/Bonjour (iOS) and NsdManager (Android)
- iOS ↔ Android cross-platform interoperability over TCP
- Pluggable transport adapter — `MessageTransport` protocol for future LoRa / acoustic adapters

### Features
- 1:1 and group text messaging, image sharing, push-to-talk voice (AAC M4A)
- Reply to message, message reactions (6-emoji), read receipts, forward message
- Disappearing messages (30 s – 7 d), per-conversation message search
- App lock — Face ID / Touch ID / passcode, auto-lock on background, App Switcher blur
- Local push notifications — grouped by thread, badge count, privacy mode (sender name hidden by default)
- Contact renaming, block peer, delete conversation
- Draft persistence, haptic feedback, clipboard auto-clear (60 s)
- Keyboard privacy — autocorrect disabled, no keyboard learning
- Screen recording warning banner, screenshot notification toast
- QR Contact Card + `sophaxchat://add` deep link
- Local AI assistant — Apple Foundation Models (iOS 26+), fully on-device
- Full account wipe — two-step confirmation, clears Keychain + messages + attachments + UserDefaults
- iPad NavigationSplitView layout; iPhone NavigationStack

### Platform
- iOS 17+, macOS 14+ (Catalyst), Android 8+
- GMS-free Android (GrapheneOS, CalyxOS, AOSP) — Wi-Fi Direct fallback, no Google Play Services
- Swift 6.2, strict concurrency

### Security audit findings resolved
- **Audit I**: group re-keying on member leave (H-1), skipped message key cache (M-1), notification content hiding on lock screen (M-4)
- **Audit II**: SKD monotonicity check (A-1), relay inner-message signature verification (A-2), global relay rate limit (A-3), TCP 120 s idle timeout (A-4), deep link confirmation gate (A-5), app lock notification clear (A-6)
- **Audit III**: Android port bounds check (S3-A1), strict Tor v3 regex (S3-A2), X3DH dhConcat zeroing (S3-I1), EncryptedSharedPreferences (S3-A3), Double Ratchet `mk.fill(0)` (S3-A4), Android clipboard auto-clear (S3-A5), dhConcat length precondition (S3-I2), error message sanitisation (S3-A6), `assert` → `precondition` (S3-I3)

### Known limitations (open)
- M-2: Sender Key Distribution may arrive after first messages in high-load scenarios
- M-3: One-time prekey exhaustion window reduces X3DH entropy temporarily
- No independent third-party security audit yet

---

[Unreleased]: https://github.com/richardmetzner/SophaxChat/compare/v0.1.0-alpha...HEAD
[0.1.0-alpha]: https://github.com/richardmetzner/SophaxChat/releases/tag/v0.1.0-alpha
