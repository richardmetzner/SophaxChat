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

echo "▶ Adding iOS Rust targets…"
rustup target add \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios

cd "$RUST_DIR"

# macOS SDK is used as SDKROOT so rustc can find system headers for cross-compilation.
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

# ── Build ─────────────────────────────────────────────────────────────────────

echo "▶ Building aarch64-apple-ios (device)…"
SDKROOT="$MACOS_SDK" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --target aarch64-apple-ios

echo "▶ Building aarch64-apple-ios-sim (Apple Silicon simulator)…"
SDKROOT="$MACOS_SDK" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --target aarch64-apple-ios-sim

echo "▶ Building x86_64-apple-ios (Intel simulator)…"
SDKROOT="$MACOS_SDK" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --target x86_64-apple-ios

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
cargo run --bin uniffi-bindgen -- generate \
    --library "target/aarch64-apple-ios/release/$LIB_NAME" \
    --language swift \
    --out-dir "$GENERATED_DIR"

echo "  Generated: $(ls "$GENERATED_DIR")"

# ── Header / modulemap paths ──────────────────────────────────────────────────

HEADERS_DEVICE="$RUST_DIR/target/headers-device"
HEADERS_SIM="$RUST_DIR/target/headers-sim"
mkdir -p "$HEADERS_DEVICE" "$HEADERS_SIM"

cp "$GENERATED_DIR/${MODULE_NAME}FFI.h"          "$HEADERS_DEVICE/"
cp "$GENERATED_DIR/${MODULE_NAME}FFI.modulemap"  "$HEADERS_DEVICE/"
cp "$GENERATED_DIR/${MODULE_NAME}FFI.h"          "$HEADERS_SIM/"
cp "$GENERATED_DIR/${MODULE_NAME}FFI.modulemap"  "$HEADERS_SIM/"

# ── Assemble XCFramework ──────────────────────────────────────────────────────

echo "▶ Assembling XCFramework…"
rm -rf "$XCFRAMEWORK"
mkdir -p "$FRAMEWORKS_DIR"

xcodebuild -create-xcframework \
    -library "$RUST_DIR/target/aarch64-apple-ios/release/$LIB_NAME" \
    -headers "$HEADERS_DEVICE" \
    -library "$SIM_FAT_DIR/$LIB_NAME" \
    -headers "$HEADERS_SIM" \
    -output "$XCFRAMEWORK"

echo ""
echo "✓ SophaxMLS.xcframework built at: $XCFRAMEWORK"
echo "✓ Swift bindings in: $GENERATED_DIR"
echo ""
echo "Next: run 'xcodegen generate' to pick up the new framework."
