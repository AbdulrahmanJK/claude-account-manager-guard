#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="${CLAUDE_GUARD_HOME:-$HOME/.claude-vpn-guard}"
CLAUDE_APP="${CLAUDE_APP_PATH:-/Applications/Claude.app}"
ENGINE_PATH="$DEST_DIR/Claude-Engine.app"
CLAUDE_SUPPORT="$HOME/Library/Application Support/Claude"
CLAUDE_JSON="$HOME/.claude.json"
PLIST_NAME="com.user.claudevpnguard.plist"
TARGET_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"
RUN_LAUNCH_AGENT="${CLAUDE_GUARD_SKIP_LAUNCH_AGENT:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DEST_DIR/backups/install-$STAMP"
STAGE="$DEST_DIR/.install-$STAMP-$$"
APP_MUTATED=0
ENGINE_MUTATED=0
OLD_APP_PRESENT=0
OLD_ENGINE_PRESENT=0
OLD_SUPPORT_LINK=""
OLD_JSON_LINK=""
OLD_ACTIVE_LINK=""
MOVED_SUPPORT=0
MOVED_JSON=0

fail() { echo "Ошибка: $*" >&2; return 1; }
link_target() { if [ -L "$1" ]; then readlink "$1"; fi; }
restore_link() {
    local path="$1" target="$2"
    if [ -L "$path" ]; then rm "$path"; fi
    if [ -n "$target" ]; then ln -s "$target" "$path"; fi
}
rollback() {
    local status="$1"
    trap - ERR
    echo "Установка прервана; восстанавливаю прежнее состояние из $BACKUP" >&2
    if [ "$RUN_LAUNCH_AGENT" != "1" ]; then
        launchctl bootout "gui/$(id -u)" "$TARGET_PLIST" 2>/dev/null || true
        if [ -f "$BACKUP/launchagent.plist" ]; then
            cp "$BACKUP/launchagent.plist" "$TARGET_PLIST"
            launchctl bootstrap "gui/$(id -u)" "$TARGET_PLIST" 2>/dev/null || true
        fi
    fi
    if [ "$APP_MUTATED" = "1" ]; then
        if [ -e "$CLAUDE_APP" ]; then mv "$CLAUDE_APP" "$BACKUP/failed-application.app" || true; fi
        if [ "$OLD_APP_PRESENT" = "1" ]; then /usr/bin/ditto "$BACKUP/application.app" "$CLAUDE_APP" || true; fi
    fi
    if [ "$ENGINE_MUTATED" = "1" ]; then
        if [ -e "$ENGINE_PATH" ]; then mv "$ENGINE_PATH" "$BACKUP/failed-engine.app" || true; fi
        if [ "$OLD_ENGINE_PRESENT" = "1" ]; then /usr/bin/ditto "$BACKUP/engine.app" "$ENGINE_PATH" || true; fi
    fi
    restore_link "$CLAUDE_SUPPORT" "$OLD_SUPPORT_LINK"
    restore_link "$CLAUDE_JSON" "$OLD_JSON_LINK"
    restore_link "$DEST_DIR/active" "$OLD_ACTIVE_LINK"
    if [ "$MOVED_SUPPORT" = "1" ] && [ -d "$DEST_DIR/profiles/work" ] && [ ! -e "$CLAUDE_SUPPORT" ]; then
        mv "$DEST_DIR/profiles/work" "$CLAUDE_SUPPORT" || true
    fi
    if [ "$MOVED_JSON" = "1" ] && [ -f "$BACKUP/original-claude.json" ] && [ ! -e "$CLAUDE_JSON" ]; then
        cp "$BACKUP/original-claude.json" "$CLAUDE_JSON" || true
    fi
    rm -rf "$STAGE"
    exit "$status"
}

for command in swiftc python3 codesign; do
    command -v "$command" >/dev/null || fail "Не найден $command"
done
mkdir -p "$DEST_DIR" "$HOME/Library/LaunchAgents"
[ ! -e "$STAGE" ] || fail "Временный каталог уже существует"
mkdir -p "$STAGE" "$BACKUP"
chmod 700 "$BACKUP"
OLD_SUPPORT_LINK="$(link_target "$CLAUDE_SUPPORT")"
OLD_JSON_LINK="$(link_target "$CLAUDE_JSON")"
OLD_ACTIVE_LINK="$(link_target "$DEST_DIR/active")"
if [ -d "$CLAUDE_APP" ]; then
    OLD_APP_PRESENT=1
    /usr/bin/ditto "$CLAUDE_APP" "$BACKUP/application.app"
fi
if [ -d "$ENGINE_PATH" ]; then
    OLD_ENGINE_PRESENT=1
    /usr/bin/ditto "$ENGINE_PATH" "$BACKUP/engine.app"
fi
if [ -d "$DEST_DIR/profiles" ]; then /usr/bin/ditto "$DEST_DIR/profiles" "$BACKUP/profiles"; fi
if [ -e "$CLAUDE_JSON" ] && [ ! -L "$CLAUDE_JSON" ]; then
    cp -p "$CLAUDE_JSON" "$BACKUP/original-claude.json"
fi
if [ -f "$TARGET_PLIST" ]; then cp -p "$TARGET_PLIST" "$BACKUP/launchagent.plist"; fi
trap 'rollback $?' ERR

if pgrep -f "$ENGINE_PATH/Contents/MacOS/Claude" >/dev/null 2>&1; then
    fail "Полностью закройте Claude (Cmd+Q) перед установкой"
fi

# Preserve an existing local configuration. New installations require explicit VPN settings.
if [ ! -f "$DEST_DIR/guard-settings.json" ]; then
    [ -n "${DEFAULT_VPN_SERVICE_NAME:-}" ] || fail "Задайте DEFAULT_VPN_SERVICE_NAME для первой установки"
    [ -n "${DEFAULT_VPN_BUNDLE_ID:-}" ] || fail "Задайте DEFAULT_VPN_BUNDLE_ID для первой установки"
    python3 - "$DEST_DIR/guard-settings.json" <<'PY'
import json, os, pathlib, sys
settings = {
    "defaultVpnServiceName": os.environ["DEFAULT_VPN_SERVICE_NAME"],
    "defaultVpnBundleId": os.environ["DEFAULT_VPN_BUNDLE_ID"],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n")
PY
    chmod 600 "$DEST_DIR/guard-settings.json"
fi
python3 - "$DEST_DIR/guard-settings.json" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
assert isinstance(data.get("defaultVpnServiceName"), str) and data["defaultVpnServiceName"]
assert isinstance(data.get("defaultVpnBundleId"), str) and data["defaultVpnBundleId"]
PY

ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) fail "Неподдерживаемая архитектура: $ARCH" ;; esac
TARGET="$ARCH-apple-macos13.0"
swiftc -O -parse-as-library -target "$TARGET" "$SOURCE_DIR/ClaudeVPNGuard.swift" "$SOURCE_DIR/DaemonMain.swift" "$SOURCE_DIR/GuardSettings.swift" "$SOURCE_DIR/VpnSafety.swift" -o "$STAGE/ClaudeVPNGuard"
swiftc -O -parse-as-library -target "$TARGET" "$SOURCE_DIR/gatekeeper-src/Gatekeeper.swift" "$SOURCE_DIR/gatekeeper-src/ProfileStore.swift" "$SOURCE_DIR/GuardSettings.swift" -o "$STAGE/Gatekeeper"
swiftc -O -parse-as-library -target "$TARGET" "$SOURCE_DIR/gatekeeper-src/ProfileCtl.swift" "$SOURCE_DIR/gatekeeper-src/ProfileStore.swift" -o "$STAGE/ProfileCtl"

APP_ID=""
if [ -d "$CLAUDE_APP" ]; then
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CLAUDE_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
case "$APP_ID" in
    com.anthropic.claudefordesktop|com.anthropic.claudefordesktop.gatekeeper|"") ;;
    *) fail "В $CLAUDE_APP находится другое приложение: $APP_ID" ;;
esac
[ -d "$ENGINE_PATH" ] || [ "$APP_ID" = "com.anthropic.claudefordesktop" ] || fail "Оригинальный Claude не найден"

mkdir -p "$STAGE/Claude.app/Contents/MacOS" "$STAGE/Claude.app/Contents/Resources"
cp "$STAGE/Gatekeeper" "$STAGE/Claude.app/Contents/MacOS/Claude"
chmod 755 "$STAGE/Claude.app/Contents/MacOS/Claude"
ICON_SOURCE="$ENGINE_PATH"
if [ ! -d "$ICON_SOURCE" ]; then ICON_SOURCE="$CLAUDE_APP"; fi
if [ -f "$ICON_SOURCE/Contents/Resources/electron.icns" ]; then
    cp "$ICON_SOURCE/Contents/Resources/electron.icns" "$STAGE/Claude.app/Contents/Resources/electron.icns"
fi
cat > "$STAGE/Claude.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Claude</string>
<key>CFBundleIconFile</key><string>electron.icns</string>
<key>CFBundleIdentifier</key><string>com.anthropic.claudefordesktop.gatekeeper</string>
<key>CFBundleName</key><string>Claude</string>
<key>CFBundleDisplayName</key><string>Claude</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>4.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$STAGE/Claude.app"
codesign --verify --deep "$STAGE/Claude.app"

PROFILES_DIR="$DEST_DIR/profiles"
WORK_DIR="$PROFILES_DIR/work"
PERSONAL_DIR="$PROFILES_DIR/personal"
mkdir -p "$PROFILES_DIR"
if [ ! -d "$WORK_DIR" ]; then
    if [ -d "$CLAUDE_SUPPORT" ] && [ ! -L "$CLAUDE_SUPPORT" ]; then
        mv "$CLAUDE_SUPPORT" "$WORK_DIR"
        MOVED_SUPPORT=1
    else
        mkdir "$WORK_DIR"
    fi
fi
mkdir -p "$PERSONAL_DIR"
if [ ! -f "$WORK_DIR/.claude.json" ]; then
    if [ -f "$CLAUDE_JSON" ] && [ ! -L "$CLAUDE_JSON" ]; then
        cp -p "$CLAUDE_JSON" "$WORK_DIR/.claude.json"
    else
        printf '{}\n' > "$WORK_DIR/.claude.json"
    fi
fi
if [ ! -f "$PERSONAL_DIR/.claude.json" ]; then printf '{}\n' > "$PERSONAL_DIR/.claude.json"; fi
if [ -f "$CLAUDE_JSON" ] && [ ! -L "$CLAUDE_JSON" ]; then
    mv "$CLAUDE_JSON" "$BACKUP/original-claude-json-in-use"
    MOVED_JSON=1
fi
if [ ! -f "$DEST_DIR/profiles.json" ]; then cp "$SOURCE_DIR/profiles.json" "$DEST_DIR/profiles.json"; fi
"$STAGE/ProfileCtl" prepare work

if [ "$APP_ID" = "com.anthropic.claudefordesktop" ]; then
    ENGINE_MUTATED=1
    if [ -d "$ENGINE_PATH" ]; then mv "$ENGINE_PATH" "$BACKUP/replaced-engine.app"; fi
    mv "$CLAUDE_APP" "$ENGINE_PATH"
fi
APP_MUTATED=1
if [ -d "$CLAUDE_APP" ]; then mv "$CLAUDE_APP" "$BACKUP/replaced-gatekeeper.app"; fi
mv "$STAGE/Claude.app" "$CLAUDE_APP"
if [ "${CLAUDE_GUARD_TEST_FAIL_AFTER_SWAP:-0}" = "1" ]; then false; fi

install -m 755 "$STAGE/ClaudeVPNGuard" "$DEST_DIR/ClaudeVPNGuard.new"
mv "$DEST_DIR/ClaudeVPNGuard.new" "$DEST_DIR/ClaudeVPNGuard"
install -m 755 "$STAGE/ProfileCtl" "$DEST_DIR/ProfileCtl.new"
mv "$DEST_DIR/ProfileCtl.new" "$DEST_DIR/ProfileCtl"
mkdir -p "$DEST_DIR/gatekeeper-src"
for file in install.sh uninstall.sh start.sh stop.sh status.sh README.md profiles.json GuardSettings.swift VpnSafety.swift ClaudeVPNGuard.swift DaemonMain.swift; do
    if [ "$file" != "profiles.json" ]; then cp "$SOURCE_DIR/$file" "$DEST_DIR/$file"; fi
done
for file in Gatekeeper.swift ProfileStore.swift ProfileCtl.swift; do
    cp "$SOURCE_DIR/gatekeeper-src/$file" "$DEST_DIR/gatekeeper-src/$file"
done
chmod 755 "$DEST_DIR"/*.sh
"$DEST_DIR/ProfileCtl" status >/dev/null
[ -d "$ENGINE_PATH" ] || fail "Движок Claude отсутствует после установки"

if [ "$RUN_LAUNCH_AGENT" != "1" ]; then
    cat > "$STAGE/$PLIST_NAME" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.user.claudevpnguard</string>
<key>ProgramArguments</key><array><string>$DEST_DIR/ClaudeVPNGuard</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$DEST_DIR/guard.log</string>
<key>StandardErrorPath</key><string>$DEST_DIR/guard.log</string>
</dict></plist>
PLIST
    launchctl bootout "gui/$(id -u)" "$TARGET_PLIST" 2>/dev/null || true
    cp "$STAGE/$PLIST_NAME" "$TARGET_PLIST"
    launchctl bootstrap "gui/$(id -u)" "$TARGET_PLIST"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$CLAUDE_APP" 2>/dev/null || true
touch "$CLAUDE_APP"
trap - ERR
rm -rf "$STAGE"
echo "Claude Guard установлен. Резервная копия: $BACKUP"
