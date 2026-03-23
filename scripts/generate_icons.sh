#!/bin/bash
# generate_icons.sh
# Generuje všechny iOS/macOS velikosti ikon z jednoho zdrojového PNG.
# Použití: ./scripts/generate_icons.sh /cesta/k/logo.png
#
# Zdroj musí být min. 1024×1024 px (čtvercový, bez průhlednosti pro App Store).
# Vyžaduje: macOS sips (je součástí macOS, žádné závislosti).

set -e

SRC="${1:-}"
if [ -z "$SRC" ]; then
    echo "Použití: $0 <cesta_k_logo.png>"
    exit 1
fi
if [ ! -f "$SRC" ]; then
    echo "Soubor nenalezen: $SRC"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT="$REPO_ROOT/SophaxChat/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$OUT"

echo "→ Generuji iOS ikony z: $SRC"
echo "→ Výstup: $OUT"

# Všechny požadované velikosti pro iOS + macOS Catalyst
declare -a SIZES=(20 29 40 48 55 58 60 64 66 76 80 87 88 92 102 120 167 172 180 196 216 234 258 1024)

for SIZE in "${SIZES[@]}"; do
    OUT_FILE="$OUT/icon_${SIZE}.png"
    sips -z "$SIZE" "$SIZE" "$SRC" --out "$OUT_FILE" > /dev/null
done

# Contents.json pro Xcode
cat > "$OUT/Contents.json" << 'EOF'
{
  "images" : [
    { "idiom":"universal", "platform":"ios", "size":"20x20",   "scale":"1x", "filename":"icon_20.png"   },
    { "idiom":"universal", "platform":"ios", "size":"20x20",   "scale":"2x", "filename":"icon_40.png"   },
    { "idiom":"universal", "platform":"ios", "size":"20x20",   "scale":"3x", "filename":"icon_60.png"   },
    { "idiom":"universal", "platform":"ios", "size":"29x29",   "scale":"1x", "filename":"icon_29.png"   },
    { "idiom":"universal", "platform":"ios", "size":"29x29",   "scale":"2x", "filename":"icon_58.png"   },
    { "idiom":"universal", "platform":"ios", "size":"29x29",   "scale":"3x", "filename":"icon_87.png"   },
    { "idiom":"universal", "platform":"ios", "size":"40x40",   "scale":"1x", "filename":"icon_40.png"   },
    { "idiom":"universal", "platform":"ios", "size":"40x40",   "scale":"2x", "filename":"icon_80.png"   },
    { "idiom":"universal", "platform":"ios", "size":"40x40",   "scale":"3x", "filename":"icon_120.png"  },
    { "idiom":"universal", "platform":"ios", "size":"60x60",   "scale":"2x", "filename":"icon_120.png"  },
    { "idiom":"universal", "platform":"ios", "size":"60x60",   "scale":"3x", "filename":"icon_180.png"  },
    { "idiom":"universal", "platform":"ios", "size":"76x76",   "scale":"1x", "filename":"icon_76.png"   },
    { "idiom":"universal", "platform":"ios", "size":"76x76",   "scale":"2x", "filename":"icon_152.png"  },
    { "idiom":"universal", "platform":"ios", "size":"83.5x83.5","scale":"2x","filename":"icon_167.png"  },
    { "idiom":"universal", "platform":"ios", "size":"1024x1024","scale":"1x","filename":"icon_1024.png" },
    { "idiom":"mac",       "platform":"macos","size":"16x16",  "scale":"1x", "filename":"icon_20.png"   },
    { "idiom":"mac",       "platform":"macos","size":"16x16",  "scale":"2x", "filename":"icon_40.png"   },
    { "idiom":"mac",       "platform":"macos","size":"32x32",  "scale":"1x", "filename":"icon_29.png"   },
    { "idiom":"mac",       "platform":"macos","size":"32x32",  "scale":"2x", "filename":"icon_58.png"   },
    { "idiom":"mac",       "platform":"macos","size":"128x128","scale":"1x", "filename":"icon_120.png"  },
    { "idiom":"mac",       "platform":"macos","size":"128x128","scale":"2x", "filename":"icon_258.png"  },
    { "idiom":"mac",       "platform":"macos","size":"256x256","scale":"1x", "filename":"icon_258.png"  },
    { "idiom":"mac",       "platform":"macos","size":"256x256","scale":"2x", "filename":"icon_1024.png" },
    { "idiom":"mac",       "platform":"macos","size":"512x512","scale":"1x", "filename":"icon_1024.png" },
    { "idiom":"mac",       "platform":"macos","size":"512x512","scale":"2x", "filename":"icon_1024.png" }
  ],
  "info" : { "author":"xcode", "version":1 }
}
EOF

echo "✓ iOS ikony vygenerovány ($(echo "${SIZES[@]}" | wc -w | tr -d ' ') souborů)"
echo "✓ Contents.json aktualizován"
echo ""
echo "Další krok: znovu spustit 'xcodegen generate' pokud jsi změnil projekt"
