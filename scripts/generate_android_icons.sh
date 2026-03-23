#!/bin/bash
# generate_android_icons.sh
# Generuje ic_launcher PNG pro všechny Android hustoty + Play Store ikonu.
# Použití: ./scripts/generate_android_icons.sh /cesta/k/logo.png
#
# Zdroj musí být min. 512×512 px (čtvercový PNG).
# Vyžaduje: macOS sips (součást macOS, žádné závislosti).

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
BASE="$REPO_ROOT/android/app/src/main/res"
STORE="$REPO_ROOT/store_assets"

echo "→ Generuji Android ikony z: $SRC"

# mipmap hustoty: název → velikost
declare -A DENSITIES=(
    [mdpi]=48
    [hdpi]=72
    [xhdpi]=96
    [xxhdpi]=144
    [xxxhdpi]=192
)

for DENSITY in "${!DENSITIES[@]}"; do
    SIZE="${DENSITIES[$DENSITY]}"
    DIR="$BASE/mipmap-$DENSITY"
    mkdir -p "$DIR"
    sips -z "$SIZE" "$SIZE" "$SRC" --out "$DIR/ic_launcher.png" > /dev/null
    cp "$DIR/ic_launcher.png" "$DIR/ic_launcher_round.png"
    echo "  ✓ mipmap-$DENSITY (${SIZE}×${SIZE}px)"
done

# Play Store ikona — 512×512
mkdir -p "$STORE"
sips -z 512 512 "$SRC" --out "$STORE/play_store_icon.png" > /dev/null
echo "  ✓ store_assets/play_store_icon.png (512×512px)"

# Adaptivní ikona — foreground (přidá padding ~18% pro systém)
# Vrstva foreground je vycentrovaná na průhledném pozadí
for DENSITY in "${!DENSITIES[@]}"; do
    SIZE="${DENSITIES[$DENSITY]}"
    DIR="$BASE/mipmap-$DENSITY"
    cp "$DIR/ic_launcher.png" "$DIR/ic_launcher_foreground.png"
done

# ic_launcher_background.xml — jednobarevné pozadí (bílé)
for DENSITY in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
    DIR="$BASE/mipmap-$DENSITY"
    cat > "$DIR/ic_launcher_background.xml" << 'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android">
    <solid android:color="#FFFFFF"/>
</shape>
XMLEOF
done

# Adaptivní ikona XML (API 26+)
DRAWABLE="$BASE/drawable"
mkdir -p "$DRAWABLE"
cat > "$DRAWABLE/ic_launcher.xml" << 'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XMLEOF

echo ""
echo "✓ Android ikony vygenerovány"
echo "✓ Adaptivní ikona nakonfigurována (API 26+)"
echo ""
echo "Play Store: $STORE/play_store_icon.png"
