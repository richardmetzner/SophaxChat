# SophaxChat — Android

Android port of SophaxChat. Uses the same wire protocol as iOS — messages between iOS and Android are end-to-end encrypted and fully interoperable.

## Status

| Component | Status |
|-----------|--------|
| Gradle project skeleton | ✅ Done |
| Wire protocol (JSON framing, all message types) | ✅ Done |
| Crypto — X3DH + Double Ratchet (lazysodium) | ✅ Done |
| TCP transport (4-byte length prefix, port 25519) | ✅ Done |
| SOCKS5 / Tor proxy support (Orbot) | ✅ Done |
| Nearby Connections mesh (GMS devices) | ✅ Done |
| Wi-Fi Direct mesh (GMS-free / AOSP / GrapheneOS) | ✅ Done |
| LAN auto-discovery via mDNS (NsdManager) | ✅ Done |
| iOS ↔ Android cross-platform messaging | ✅ Done |
| Group messaging (Sender Keys) | ✅ Done |
| Encrypted attachment store (images, audio) | ✅ Done |
| Jetpack Compose UI | 🚧 In progress |

## Cross-platform interoperability

iOS and Android automatically discover each other on the same WiFi network via **mDNS** (iOS Bonjour / Android NsdManager). Once discovered, they connect over TCP on port 25519 using the shared wire protocol. All encryption (X3DH, Double Ratchet, ChaCha20-Poly1305) is identical on both platforms.

For internet reach, both platforms support Tor via Orbot (SOCKS5 proxy on `127.0.0.1:9050`).

## GMS-free support

On devices without Google Play Services (GrapheneOS, CalyxOS, LineageOS), SophaxChat automatically falls back to **Wi-Fi Direct** via the stock Android `android.net.wifi.p2p.*` API — no GMS dependency whatsoever. LAN discovery via NsdManager works on all Android devices regardless of GMS.

Runtime detection — no GMS imports:
```kotlin
private fun isNearbyAvailable(context: Context): Boolean = runCatching {
    context.packageManager.getPackageInfo("com.google.android.gms", 0)
    Class.forName("com.google.android.gms.nearby.Nearby")
    true
}.getOrDefault(false)
```

## Building

Prerequisites: Android Studio Meerkat or later, JDK 17+.

```bash
cd android
./gradlew assembleDebug
```

## Architecture

```
android/app/src/main/java/.../
├── crypto/
│   ├── DoubleRatchet.kt        # Double Ratchet + Header Encryption
│   ├── X3DH.kt                 # X3DH sender + receiver
│   ├── IdentityManager.kt      # Ed25519 + X25519 keypairs (Android Keystore)
│   └── PreKeyManager.kt        # OPK pool + SPK rotation
├── network/
│   ├── TcpTransport.kt         # TCP transport, SOCKS5, 4-byte framing
│   ├── LanDiscovery.kt         # mDNS discovery (NsdManager)
│   ├── NearbyManager.kt        # Nearby Connections (GMS)
│   └── WifiDirectManager.kt    # Wi-Fi Direct P2P (GMS-free)
├── storage/
│   ├── MessageStore.kt         # AES-256-GCM at-rest storage
│   └── AttachmentStore.kt      # Encrypted blob store
└── ChatManager.kt              # High-level coordinator
```

## Contributing

See [`../.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).
