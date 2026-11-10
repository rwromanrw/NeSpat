#!/bin/bash
# Сборка «Не спать». Использование: ./scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build"
APP="$BUILD_DIR/NeSpat.app"
# Чтобы Spotlight не плодил копии из папки сборки
mkdir -p "$BUILD_DIR"
touch "$BUILD_DIR/.metadata_never_index"

swift build -c release 2>&1

BIN="$(swift build -c release --show-bin-path)/NeSpat"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NeSpat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep -s - "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo "Готово: $APP"
echo "Проверка без GUI: $APP/Contents/MacOS/NeSpat --print-stats"

if [[ "${1:-}" == "--install" ]]; then
    # Системные «Программы», если можно писать; иначе ~/Applications
    if [[ -w /Applications ]]; then
        DEST="/Applications/NeSpat.app"
    else
        mkdir -p "$HOME/Applications"
        DEST="$HOME/Applications/NeSpat.app"
    fi
    # Одна копия: убрать обе цели и сборочный .app из индекса
    rm -rf /Applications/NeSpat.app "$HOME/Applications/NeSpat.app"
    cp -R "$APP" "$DEST"
    rm -rf "$APP"
    echo "Установлено: $DEST"
    echo "Чтобы найти: Finder → Программы → Не спать (или кнопка в панели приложения)"
fi
