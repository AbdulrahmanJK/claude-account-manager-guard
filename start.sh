#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.user.claudevpnguard.plist"
if [ -f "$PLIST" ]; then
    if launchctl print "gui/$(id -u)/com.user.claudevpnguard" >/dev/null 2>&1; then
        echo "ClaudeVPNGuard уже запущен через LaunchAgent."
    else
        launchctl bootstrap "gui/$(id -u)" "$PLIST"
        echo "ClaudeVPNGuard запущен через LaunchAgent."
    fi
else
    if pgrep -f "$DIR/ClaudeVPNGuard" >/dev/null; then
        echo "ClaudeVPNGuard уже запущен."
    else
        nohup "$DIR/ClaudeVPNGuard" > "$DIR/guard.log" 2>&1 &
        echo "ClaudeVPNGuard запущен: $!"
    fi
fi
