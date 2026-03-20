# SophaxChat — Android

> Work in progress. The iOS app is the primary platform. Android port is planned.

## Status

| Component | Status |
|-----------|--------|
| Gradle project skeleton | Done |
| Wire protocol implementation | Planned |
| Crypto (X3DH + Double Ratchet) | Planned |
| BLE + Wi-Fi Direct mesh | Planned |
| TCP/Tor transport | Planned |
| Jetpack Compose UI | Planned |

## Architecture plan

The Android port will reuse the **same wire protocol** as iOS — see [`../docs/protocol.md`](../docs/protocol.md).

Crypto will be implemented using [libsodium](https://github.com/jedisct1/libsodium) via `lazysodium-android`, which provides the same Ed25519 / X25519 / ChaCha20-Poly1305 primitives as Apple CryptoKit.

The mesh transport will use **Android Nearby Connections API** (Wi-Fi Direct + BLE) as the equivalent of iOS MultipeerConnectivity.

## Building

Prerequisites: Android Studio Meerkat or later, JDK 17+.

```bash
cd android
./gradlew assembleDebug
```

## Contributing

See [`../.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).
