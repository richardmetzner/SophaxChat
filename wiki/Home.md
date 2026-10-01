# SophaxChat

**Anonymous · Offline · End-to-end encrypted mesh chat**

Works over Bluetooth LE and WiFi Direct — no internet, no servers, no account.  
Reach anyone globally by routing through Tor (via Orbot).  
Your identity is a Curve25519 key pair generated on your device. Nothing is ever sent to a server.

---

## Quick start

### iOS / macOS

```bash
brew install xcodegen
git clone https://github.com/richardmetzner/SophaxChat
cd SophaxChat
xcodegen generate
open SophaxChat.xcodeproj   # then ⌘R on a physical device
```

> Physical device required — MultipeerConnectivity (BLE/WiFi P2P) does not work in Simulator.

**Mac (no Apple Developer account needed):**  
Select *My Mac (Designed for iPad)* as the run destination.

### Android

```bash
cd android
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

See [`android/README.md`](https://github.com/richardmetzner/SophaxChat/blob/main/android/README.md) for full instructions.

---

## Wiki pages

| Page | Contents |
|---|---|
| [[Protocol]] | Wire message format, session lifecycle, relay routing |
| [[Cryptography]] | Key types, X3DH, Double Ratchet, Header Encryption, Sealed Sender |

---

## Key links

- [README](https://github.com/richardmetzner/SophaxChat#readme) — full feature list, architecture, getting started
- [SECURITY.md](https://github.com/richardmetzner/SophaxChat/blob/main/SECURITY.md) — threat model, responsible disclosure
- [CONTRIBUTING.md](https://github.com/richardmetzner/SophaxChat/blob/main/.github/CONTRIBUTING.md) — how to contribute
- [CHANGELOG](https://github.com/richardmetzner/SophaxChat/blob/main/CHANGELOG.md) — release history
- [Open issues](https://github.com/richardmetzner/SophaxChat/issues)

---

## Philosophy

1. **No servers.** Every feature works peer-to-peer.
2. **No identity leakage.** No phone number, no email, no account.
3. **Maximum cryptographic protection.** X3DH + Double Ratchet + Header Encryption + Sealed Sender — not features, the baseline.
