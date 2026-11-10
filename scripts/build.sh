#!/bin/bash
# Сборка «Не спать». Использование: ./scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build"
APP="$BUILD_DIR/NeSpat.app"

swift build -c release 2>&1

BIN="$(swift build -c release --show-bin-path)/NeSpat"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NeSpat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep -s - "$APP"

echo "Готово: $APP"
echo "Проверка без GUI: $APP/Contents/MacOS/NeSpat --print-stats"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/NeSpat.app"
    cp -R "$APP" "$HOME/Applications/NeSpat.app"
    echo "Установлено: ~/Applications/NeSpat.app"
fi
