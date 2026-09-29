#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.user.claudevpnguard.plist"
if launchctl print "gui/$(id -u)/com.user.claudevpnguard" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)" "$PLIST"
    echo "ClaudeVPNGuard остановлен."
else
    PIDS="$(pgrep -f "$DIR/ClaudeVPNGuard" || true)"
    if [ -n "$PIDS" ]; then kill $PIDS; fi
    echo "ClaudeVPNGuard остановлен."
fi
