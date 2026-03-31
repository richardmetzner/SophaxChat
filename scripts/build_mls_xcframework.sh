#!/usr/bin/env bash
# build_mls_xcframework.sh
# Compiles the sophax-mls Rust crate for all iOS targets, generates UniFFI Swift
# bindings, and assembles an XCFramework at Frameworks/SophaxMLS.xcframework.
#
# Requirements:
#   brew install xcodegen   (for project rebuild after)
#   rustup targets installed (script installs them if missing)
#   Xcode Command Line Tools with iphoneos SDK

set -euo pipefail

# Use full Xcode if available (required for xcodebuild -create-xcframework).
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"
GENERATED_DIR="$REPO_ROOT/Sources/SophaxChatCore/MLS/Generated"
XCFRAMEWORK="$FRAMEWORKS_DIR/SophaxMLS.xcframework"

LIB_NAME="libsophax_mls.a"
MODULE_NAME="sophax_mls"

# ── Source Cargo/rustup ──────────────────────────────────────────────────────

source "$HOME/.cargo/env" 2>/dev/null || true

# ── Add targets ──────────────────────────────────────────────────────────────

echo "▶ Adding Rust targets…"
rustup target add \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios \
    aarch64-apple-darwin

cd "$RUST_DIR"

# macOS SDK is used as SDKROOT so rustc can find system headers for cross-compilation.
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

# ── Build ─────────────────────────────────────────────────────────────────────

echo "▶ Building aarch64-apple-ios (device)…"
SDKROOT="$MACOS_SDK" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --lib --target aarch64-apple-ios

echo "▶ Building aarch64-apple-ios-sim (Apple Silicon simulator)…"
SDKROOT="$MACOS_SDK" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --lib --target aarch64-apple-ios-sim

echo "▶ Building x86_64-apple-ios (Intel simulator)…"
SDKROOT="$MACOS_SDK" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --lib --target x86_64-apple-ios

echo "▶ Building aarch64-apple-darwin (macOS arm64 — needed for swift build / SPM)…"
cargo build --release --lib --target aarch64-apple-darwin

# ── Fat simulator lib (lipo) ──────────────────────────────────────────────────

SIM_FAT_DIR="$RUST_DIR/target/sim-fat/release"
mkdir -p "$SIM_FAT_DIR"

echo "▶ Creating fat simulator library (arm64 + x86_64)…"
lipo -create \
    "$RUST_DIR/target/aarch64-apple-ios-sim/release/$LIB_NAME" \
    "$RUST_DIR/target/x86_64-apple-ios/release/$LIB_NAME" \
    -output "$SIM_FAT_DIR/$LIB_NAME"

# ── Generate Swift bindings ───────────────────────────────────────────────────

echo "▶ Generating UniFFI Swift bindings…"
mkdir -p "$GENERATED_DIR"
# Build uniffi-bindgen for host only (no --target flag), then run it
cargo build --bin uniffi-bindgen
cargo run --bin uniffi-bindgen -- generate \
    --library "target/aarch64-apple-ios/release/$LIB_NAME" \
    --language swift \
    --out-dir "$GENERATED_DIR"

echo "  Generated: $(ls "$GENERATED_DIR")"

# ── Header / modulemap paths ──────────────────────────────────────────────────

HEADERS_DEVICE="$RUST_DIR/target/headers-device"
HEADERS_SIM="$RUST_DIR/target/headers-sim"
HEADERS_MACOS="$RUST_DIR/target/headers-macos"
mkdir -p "$HEADERS_DEVICE" "$HEADERS_SIM" "$HEADERS_MACOS"

for DIR in "$HEADERS_DEVICE" "$HEADERS_SIM" "$HEADERS_MACOS"; do
    cp "$GENERATED_DIR/${MODULE_NAME}FFI.h"         "$DIR/"
    # Xcode/SPM require the modulemap to be named "module.modulemap" to find it automatically.
    cp "$GENERATED_DIR/${MODULE_NAME}FFI.modulemap" "$DIR/module.modulemap"
done

# ── Assemble XCFramework ──────────────────────────────────────────────────────

echo "▶ Assembling XCFramework…"
rm -rf "$XCFRAMEWORK"
mkdir -p "$FRAMEWORKS_DIR"

xcodebuild -create-xcframework \
    -library "$RUST_DIR/target/aarch64-apple-ios/release/$LIB_NAME" \
    -headers "$HEADERS_DEVICE" \
    -library "$SIM_FAT_DIR/$LIB_NAME" \
    -headers "$HEADERS_SIM" \
    -library "$RUST_DIR/target/aarch64-apple-darwin/release/$LIB_NAME" \
    -headers "$HEADERS_MACOS" \
    -output "$XCFRAMEWORK"

echo ""
echo "✓ SophaxMLS.xcframework built at: $XCFRAMEWORK"
echo "✓ Swift bindings in: $GENERATED_DIR"
echo ""
echo "Next: run 'xcodegen generate' to pick up the new framework."
