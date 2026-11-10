#!/bin/bash
# Установка сторожа (LaunchAgent пользователя). Ставится только с согласия владельца.
# Сторож НЕ автозапускает приложение: он только возвращает обычный сон, если сессия наша,
# а приложение не запущено (или зависло), либо истёк таймер/критичны батарея/нагрев.
set -euo pipefail

APP_PATH="${1:-$HOME/Applications/NeSpat.app}"
PLIST="$HOME/Library/LaunchAgents/local.nespat.watchdog.plist"

if [[ ! -x "$APP_PATH/Contents/MacOS/NeSpat" ]]; then
    echo "Нет приложения: $APP_PATH (сначала ./scripts/build.sh --install)" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/local.nespat.watchdog" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.nespat.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_PATH/Contents/MacOS/NeSpat</string>
        <string>--watchdog</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Сторож установлен: $PLIST (каждые 30 с)"
