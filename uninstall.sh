#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEST_DIR="${CLAUDE_GUARD_HOME:-$HOME/.claude-vpn-guard}"
CLAUDE_APP="${CLAUDE_APP_PATH:-/Applications/Claude.app}"
ENGINE_PATH="$DEST_DIR/Claude-Engine.app"
CLAUDE_SUPPORT="$HOME/Library/Application Support/Claude"
CLAUDE_JSON="$HOME/.claude.json"
TARGET_PLIST="$HOME/Library/LaunchAgents/com.user.claudevpnguard.plist"
SKIP_AGENT="${CLAUDE_GUARD_SKIP_LAUNCH_AGENT:-0}"
BACKUP="$DEST_DIR/backups/uninstall-$(date +%Y%m%d-%H%M%S)"
MOVED_WORK=0
MOVED_ENGINE=0
MOVED_APP=0
OLD_SUPPORT_LINK=""
OLD_JSON_LINK=""

fail() { echo "Ошибка: $*" >&2; return 1; }
link_target() { if [ -L "$1" ]; then readlink "$1"; fi; }
rollback() {
    local status="$1"
    trap - ERR
    echo "Удаление прервано; восстанавливаю прежнее состояние из $BACKUP" >&2
    if [ "$MOVED_ENGINE" = "1" ] && [ -d "$CLAUDE_APP" ]; then
        mv "$CLAUDE_APP" "$ENGINE_PATH" || true
    fi
    if [ "$MOVED_APP" = "1" ] && [ -d "$BACKUP/replaced-gatekeeper.app" ]; then
        mv "$BACKUP/replaced-gatekeeper.app" "$CLAUDE_APP" || true
    fi
    if [ "$MOVED_WORK" = "1" ] && [ -d "$CLAUDE_SUPPORT" ] && [ ! -L "$CLAUDE_SUPPORT" ]; then
        mv "$CLAUDE_SUPPORT" "$DEST_DIR/profiles/work" || true
    fi
    if [ -L "$CLAUDE_SUPPORT" ]; then rm "$CLAUDE_SUPPORT"; fi
    if [ -n "$OLD_SUPPORT_LINK" ]; then ln -s "$OLD_SUPPORT_LINK" "$CLAUDE_SUPPORT"; fi
    if [ -L "$CLAUDE_JSON" ] || [ -f "$CLAUDE_JSON" ]; then rm "$CLAUDE_JSON"; fi
    if [ -n "$OLD_JSON_LINK" ]; then ln -s "$OLD_JSON_LINK" "$CLAUDE_JSON"; fi
    if [ "$SKIP_AGENT" != "1" ] && [ -f "$BACKUP/launchagent.plist" ]; then
        cp "$BACKUP/launchagent.plist" "$TARGET_PLIST"
        launchctl bootstrap "gui/$(id -u)" "$TARGET_PLIST" 2>/dev/null || true
    fi
    exit "$status"
}

[ -d "$ENGINE_PATH" ] || fail "Оригинальный движок Claude не найден"
[ -d "$DEST_DIR/profiles/work" ] || fail "Рабочий профиль не найден"
[ -f "$DEST_DIR/profiles/work/.claude.json" ] || fail "Файл конфигурации рабочего профиля не найден"
[ -L "$CLAUDE_SUPPORT" ] || fail "Application Support/Claude не является ссылкой"
[ -L "$CLAUDE_JSON" ] || fail "~/.claude.json не является ссылкой"
if pgrep -f "$ENGINE_PATH/Contents/MacOS/Claude" >/dev/null 2>&1; then
    fail "Полностью закройте Claude (Cmd+Q) перед удалением"
fi
OLD_SUPPORT_LINK="$(link_target "$CLAUDE_SUPPORT")"
OLD_JSON_LINK="$(link_target "$CLAUDE_JSON")"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
/usr/bin/ditto "$DEST_DIR/profiles" "$BACKUP/profiles"
/usr/bin/ditto "$ENGINE_PATH" "$BACKUP/engine.app"
if [ -d "$CLAUDE_APP" ]; then /usr/bin/ditto "$CLAUDE_APP" "$BACKUP/application.app"; fi
if [ -f "$TARGET_PLIST" ]; then cp -p "$TARGET_PLIST" "$BACKUP/launchagent.plist"; fi
trap 'rollback $?' ERR

if [ "$SKIP_AGENT" != "1" ] && [ -f "$TARGET_PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$TARGET_PLIST" 2>/dev/null || true
    mv "$TARGET_PLIST" "$BACKUP/removed-launchagent.plist"
fi

rm "$CLAUDE_SUPPORT"
mv "$DEST_DIR/profiles/work" "$CLAUDE_SUPPORT"
MOVED_WORK=1
rm "$CLAUDE_JSON"
cp -p "$CLAUDE_SUPPORT/.claude.json" "$CLAUDE_JSON"

if [ -d "$CLAUDE_APP" ]; then
    mv "$CLAUDE_APP" "$BACKUP/replaced-gatekeeper.app"
    MOVED_APP=1
fi
mv "$ENGINE_PATH" "$CLAUDE_APP"
MOVED_ENGINE=1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$CLAUDE_APP" 2>/dev/null || true
touch "$CLAUDE_APP"
trap - ERR
echo "Оригинальный Claude восстановлен. Остальные профили и резервная копия сохранены в $DEST_DIR."
