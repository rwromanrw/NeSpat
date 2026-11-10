#!/bin/bash
# Полное удаление: приложение, сторож, правило sudoers, файлы состояния и логи.
# Сон возвращается, только если сессию включило это приложение (или с флагом --force-sleep).
set -euo pipefail

FORCE_SLEEP=0
[[ "${1:-}" == "--force-sleep" ]] && FORCE_SLEEP=1

echo "== Сторож =="
launchctl bootout "gui/$(id -u)/local.nespat.watchdog" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.nespat.watchdog.plist"

echo "== Приложение =="
rm -rf "$HOME/Applications/NeSpat.app"

echo "== Правило sudoers =="
if [[ -f /etc/sudoers.d/ne-spat ]]; then
    sudo rm -f /etc/sudoers.d/ne-spat
    echo "удалено /etc/sudoers.d/ne-spat (остаток старой схемы)"
else
    echo "нет (пароль вводится в системном диалоге)"
fi

echo "== Сон =="
SESSION="$HOME/Library/Application Support/NeSpat/session.json"
OWNED=0
if [[ -f "$SESSION" ]] && grep -q '"owned":true' "$SESSION" 2>/dev/null; then OWNED=1; fi
if [[ $OWNED == 1 || $FORCE_SLEEP == 1 ]]; then
    sudo -n /usr/bin/pmset -a disablesleep 0 || sudo /usr/bin/pmset -a disablesleep 0
    echo "сон возвращён"
else
    echo "сессия не наша — флаг сна не трогаем (снять вручную: sudo /usr/bin/pmset -a disablesleep 0)"
fi

echo "== Файлы =="
rm -rf "$HOME/Library/Application Support/NeSpat"
rm -rf "$HOME/Library/Logs/NeSpat"

echo "Готово."
