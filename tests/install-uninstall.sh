#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /private/tmp/claude-guard-install-test.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
export HOME="$FIXTURE/home"
export CLAUDE_GUARD_HOME="$HOME/.claude-vpn-guard"
export CLAUDE_APP_PATH="$FIXTURE/Applications/Claude.app"
export CLAUDE_GUARD_SKIP_LAUNCH_AGENT=1
export CLANG_MODULE_CACHE_PATH=/private/tmp/claude-guard-swift-cache
export SWIFT_MODULECACHE_PATH=/private/tmp/claude-guard-swift-cache
export DEFAULT_VPN_SERVICE_NAME="Example VPN"
export DEFAULT_VPN_BUNDLE_ID="com.example.vpn"
mkdir -p "$CLAUDE_APP_PATH/Contents/MacOS" "$HOME/Library/Application Support/Claude"
cat > "$CLAUDE_APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.anthropic.claudefordesktop</string>
<key>CFBundleExecutable</key><string>Claude</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_APP_PATH/Contents/MacOS/Claude"
chmod +x "$CLAUDE_APP_PATH/Contents/MacOS/Claude"
printf 'local-session-preserved\n' > "$HOME/Library/Application Support/Claude/session.fixture"
printf '{"fixture":true}\n' > "$HOME/.claude.json"

"$ROOT/install.sh" >/dev/null
test -f "$CLAUDE_GUARD_HOME/profiles/work/session.fixture"
test "$(readlink "$HOME/Library/Application Support/Claude")" = "$CLAUDE_GUARD_HOME/active"
test "$(readlink "$HOME/.claude.json")" = "$CLAUDE_GUARD_HOME/active/.claude.json"
"$CLAUDE_GUARD_HOME/ProfileCtl" switch personal >/dev/null
BEFORE_HASH="$(shasum -a 256 "$CLAUDE_APP_PATH/Contents/MacOS/Claude" | awk '{print $1}')"
if CLAUDE_GUARD_TEST_FAIL_AFTER_SWAP=1 "$ROOT/install.sh" >/dev/null 2>&1; then
    echo "Expected installer rollback did not occur" >&2
    exit 1
fi
test "$(shasum -a 256 "$CLAUDE_APP_PATH/Contents/MacOS/Claude" | awk '{print $1}')" = "$BEFORE_HASH"
test "$("$CLAUDE_GUARD_HOME/ProfileCtl" status)" = personal
"$ROOT/install.sh" >/dev/null
test "$("$CLAUDE_GUARD_HOME/ProfileCtl" status)" = personal
test -f "$CLAUDE_GUARD_HOME/profiles/work/session.fixture"
"$ROOT/uninstall.sh" >/dev/null
test -f "$HOME/Library/Application Support/Claude/session.fixture"
test -f "$HOME/.claude.json"
test "$(defaults read "$CLAUDE_APP_PATH/Contents/Info.plist" CFBundleIdentifier)" = com.anthropic.claudefordesktop
test -d "$CLAUDE_GUARD_HOME/profiles/personal"
echo "Installer: install, reinstall, profile preservation and uninstall passed"
