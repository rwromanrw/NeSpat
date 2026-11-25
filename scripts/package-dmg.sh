#!/bin/bash
# Собирает DMG для передачи другим: NeSpat-1.3.dmg
# Использование: ./scripts/package-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.3"
APP_NAME="NeSpat"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGING="build/dmg-staging"
VOL="${APP_NAME}"

./scripts/build.sh

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "build/${APP_NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# Короткая инструкция рядом
cat > "$STAGING/Установка.txt" <<'EOF'
Не спать — установка

1. Перетащите NeSpat.app в папку Applications (ярлык рядом).
2. Откройте из Launchpad или Finder → Applications.
3. При первом запуске: если macOS скажет «невозможно открыть»,
   щелкните правой кнопкой → Открыть → Открыть.
4. В строке меню появятся температура, CPU и память.
5. Включение и выключение «Не спать» — macOS спросит пароль администратора
   (так устроен pmset disablesleep; постоянных sudoers нет).

Сторож (опционально, если приложение упало — вернуть сон):
  см. README в исходниках / на GitHub.

Удаление:
  ./scripts/uninstall.sh  (из исходников) или просто удалите .app
EOF

rm -f "build/${DMG_NAME}"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "build/${DMG_NAME}"

rm -rf "$STAGING"
echo "Готово: build/${DMG_NAME}"
echo "Можно передать этот файл другому человеку."
