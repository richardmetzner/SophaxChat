# Contributing to SophaxChat

Thanks for your interest in contributing. SophaxChat is a security-focused project — please read this before submitting code.

## Philosophy

This project has a formal philosophy document. **Read [PHILOSOPHY.md](../PHILOSOPHY.md) before contributing.** By submitting a pull request, you agree to its principles.

The short version:

- **No servers.** Every feature must work without a central server.
- **No accounts.** Identity is cryptographic, not email/phone-based.
- **No tracking.** No analytics, no crash reporters that phone home.
- **Minimal dependencies.** Every dependency is a potential attack surface.

## Building

### iOS / macOS

Prerequisites: Xcode 15+, XcodeGen.

```bash
brew install xcodegen
xcodegen generate
open SophaxChat.xcodeproj
```

Press **⌘R** to build and run. A physical device is required for MultipeerConnectivity (Simulator does not support P2P).

The core library (`SophaxChatCore`) can be built without Xcode:

```bash
swift build
swift test
```

### Android

Prerequisites: Android Studio Meerkat or later, JDK 17+.

```bash
cd android
./gradlew assembleDebug
```

See [`android/README.md`](../android/README.md) for details on the Android port status.

## Protocol compatibility

The iOS and Android apps must interoperate. Any change to the wire format must be documented in [`docs/protocol.md`](../docs/protocol.md) and must maintain backward compatibility or include a versioning mechanism.

## Security issues

Do **not** open a public GitHub issue for security vulnerabilities. See [`SECURITY.md`](../SECURITY.md) for responsible disclosure instructions.

## Pull requests

- Keep PRs focused — one feature or fix per PR.
- Include a brief description of *why*, not just *what*.
- Crypto changes require a clear explanation of the security model impact.
- All Swift code must compile with strict concurrency checking (`-strict-concurrency=complete`).
