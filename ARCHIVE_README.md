# SophaxChat — archived 2026

Serverless, end-to-end encrypted messenger for iOS, macOS and Android. No servers, no phone number, no account. Identity is a locally generated Curve25519 keypair.

**Built with:** Swift 6.2 / SwiftUI (iOS 17+, macOS 14+), Kotlin / Compose (Android 8+), and a small Rust crate (`sophax-mls`, mls-rs 0.54) exposed to Swift through UniFFI as a binary XCFramework. Roughly 25k lines Swift, 10k Kotlin, 400 Rust. SPM + Xcodegen, MIT licensed, 359 commits, tagged `0.1.0-alpha` on 2026-04-01.

**What worked.** The cryptographic core is complete: X3DH session setup, Double Ratchet with header encryption, sealed sender, Ed25519 message signatures, ChaCha20-Poly1305 in transit, AES-256-GCM at rest, Sender Keys v2 for groups, MLS (RFC 9420) for per-epoch post-compromise security, SHA-512 safety numbers with QR verification, TOFU key-change warnings, Shamir-split identity backup, and an HMAC-verified key transparency log. Transport worked too: Bluetooth LE / WiFi Direct mesh via MultipeerConnectivity, TCP over Tor with `.onion` addresses derived from the identity key, six-hop flood relay with LRU dedup, 48-hour store-and-forward, mDNS discovery, and verified iOS↔Android interop. Shipped features include 1:1 and group chat, images, files, push-to-talk voice, duress PIN with a decoy app, and encrypted full export.

**What didn't.** It never left alpha and was never independently audited — the blocker for everything downstream. MLS group *creation* was never wired into the UI, so MLS only applied to existing groups. Groups can be left but not deleted. DHT peer discovery has an engine (`Sources/SophaxChatCore/DHT/`) but the announce path was never shipped. Android device linking still opens a stub. English only, no TestFlight build, no demo recording. Funding was being sought from NLnet NGI Zero to cover the audit and Apple Developer membership; that didn't land.

---

## Archive notes

Removed during archiving, all regenerable:

- `rust/target/` (3.4 GB) — `cargo build` from `rust/`
- `.build/` (192 MB) — `swift build`
- `Frameworks/SophaxMLS.xcframework` (147 MB) — rebuild with `bash scripts/build_mls_xcframework.sh`; the Rust source in `rust/src/` and the generated UniFFI bindings in `Sources/SophaxChatCore/MLS/Generated/` are both retained
- `.claude/worktrees/` (6.6 MB) — duplicate agent checkouts

Git history is complete (359 commits). `.git` went from 906 MB to 82 MB via `git gc --prune=now`; no commits were rewritten and `HEAD` is unchanged.

To restore a working build: `bash scripts/setup_frameworks.sh` then `bash scripts/build_mls_xcframework.sh`.
