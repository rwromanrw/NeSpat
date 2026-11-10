#!/bin/bash
# Установка сторожа (LaunchAgent пользователя). Ставится только с согласия владельца.
# Сторож НЕ автозапускает приложение: он только возвращает обычный сон, если сессия наша,
# а приложение не запущено (или зависло), либо истёк таймер/критичны батарея/нагрев.
set -euo pipefail

# Предпочитаем /Applications (куда ставит build.sh --install), иначе ~/Applications.
if [[ -n "${1:-}" ]]; then
    APP_PATH="$1"
elif [[ -x "/Applications/NeSpat.app/Contents/MacOS/NeSpat" ]]; then
    APP_PATH="/Applications/NeSpat.app"
elif [[ -x "$HOME/Applications/NeSpat.app/Contents/MacOS/NeSpat" ]]; then
    APP_PATH="$HOME/Applications/NeSpat.app"
else
    echo "Нет приложения NeSpat.app (сначала ./scripts/build.sh --install)" >&2
    exit 1
fi

PLIST="$HOME/Library/LaunchAgents/local.nespat.watchdog.plist"
BIN="$APP_PATH/Contents/MacOS/NeSpat"

if [[ ! -x "$BIN" ]]; then
    echo "Нет исполняемого файла: $BIN" >&2
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
        <string>$BIN</string>
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
echo "Сторож установлен: $PLIST"
echo "Бинарник: $BIN (каждые 30 с)"
echo "Если приложение упало при включённом режиме — macOS может один раз спросить пароль, чтобы вернуть сон."
