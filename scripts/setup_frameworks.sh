#!/usr/bin/env bash
# setup_frameworks.sh
# Downloads pre-built binary dependencies that are too large for git.
# Run once before opening SophaxChat.xcodeproj.
#
# Dependencies:
#   tor.xcframework — iCepa/Tor.framework v409.5.1
#     Binary: libevent + OpenSSL + Tor (arm64 device + arm64/x86_64 simulator + macOS)
#     SHA-256 verified after download.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"

TOR_VERSION="409.5.1"
TOR_ZIP_URL="https://github.com/iCepa/Tor.framework/releases/download/v${TOR_VERSION}/tor.xcframework.zip"
TOR_ZIP_SHA256="UNVERIFIED"   # TODO: replace with actual SHA256 from iCepa release page
TOR_DEST="$FRAMEWORKS_DIR/tor.xcframework"

echo "==> Setting up Frameworks/"
mkdir -p "$FRAMEWORKS_DIR"

# ── Tor.framework ──────────────────────────────────────────────────────────────
if [ -d "$TOR_DEST" ]; then
    echo "    tor.xcframework already present — skipping download."
else
    echo "    Downloading tor.xcframework v${TOR_VERSION}..."
    TMP=$(mktemp -d)
    trap "rm -rf $TMP" EXIT

    curl -fSL --progress-bar "$TOR_ZIP_URL" -o "$TMP/tor.zip"

    # Verify integrity before unpacking
    if [ "$TOR_ZIP_SHA256" != "UNVERIFIED" ]; then
        ACTUAL=$(shasum -a 256 "$TMP/tor.zip" | awk '{print $1}')
        if [ "$ACTUAL" != "$TOR_ZIP_SHA256" ]; then
            echo "ERROR: SHA-256 mismatch for tor.zip"
            echo "  expected: $TOR_ZIP_SHA256"
            echo "  got:      $ACTUAL"
            exit 1
        fi
        echo "    SHA-256 verified ✓"
    else
        echo "    WARNING: SHA-256 not configured — skipping integrity check."
        echo "    Verify the download manually before building."
    fi

    unzip -q "$TMP/tor.zip" -d "$FRAMEWORKS_DIR"
    echo "    tor.xcframework installed ✓"
fi

echo ""
echo "Done. Run 'xcodegen generate' if needed, then open SophaxChat.xcodeproj."
