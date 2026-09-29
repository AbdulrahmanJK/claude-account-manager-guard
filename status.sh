#!/usr/bin/env bash

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/ClaudeVPNGuard"

echo "=== Статус Claude VPN Guard v4.0 (Multi-Account) ==="

# 1. Процесс демона
PID=$(pgrep -f "$BIN" || true)
if [ -n "$PID" ]; then
    echo "🟢 Демон активен (PID: $PID)"
else
    echo "⚪️ Демон выключен"
fi

# 2. Статус приложения Claude Engine
CLAUDE_PID=$(pgrep -f "Claude-Engine" || true)
if [ -n "$CLAUDE_PID" ]; then
    echo "🟢 Claude (Engine): ЗАПУЩЕН (PID: $CLAUDE_PID)"
else
    echo "⚪️ Claude (Engine): НЕ запущен"
fi

# 3. Активный профиль
PROFILE_FILE="$DIR/current_profile.txt"
PROFILES_JSON="$DIR/profiles.json"
ACTIVE_LINK="$DIR/active"
if [ -L "$ACTIVE_LINK" ] || [ -f "$PROFILE_FILE" ]; then
    if [ -L "$ACTIVE_LINK" ]; then
        CURR_PROF=$(basename "$(readlink "$ACTIVE_LINK")")
    else
        CURR_PROF=$(tr -d ' \n' < "$PROFILE_FILE")
    fi
    PROF_NAME="$CURR_PROF"

    if [ -f "$PROFILES_JSON" ]; then
        FOUND_NAME=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); ident=sys.argv[2]; print(next((x.get("name", x["id"]) for x in data if x["id"]==ident), ident))' "$PROFILES_JSON" "$CURR_PROF" 2>/dev/null || echo "$CURR_PROF")
        [ -n "$FOUND_NAME" ] && PROF_NAME="$FOUND_NAME"
    elif [ "$CURR_PROF" == "work" ]; then
        PROF_NAME="Рабочий"
    elif [ "$CURR_PROF" == "personal" ]; then
        PROF_NAME="Личный"
    fi

    EMAIL_INFO=""
    CLAUDE_JSON_TARGET="$DIR/profiles/$CURR_PROF/.claude.json"
    EMAIL=""
    if [ -f "$CLAUDE_JSON_TARGET" ]; then
        EMAIL=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data.get("oauthAccount", {}).get("emailAddress", data.get("emailAddress", "")))' "$CLAUDE_JSON_TARGET" 2>/dev/null || echo "")
    fi
    if [ -z "$EMAIL" ]; then
        EMAIL=$(grep -aroE "email_address[^a-zA-Z0-9._%+-]+[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "$DIR/profiles/$CURR_PROF/IndexedDB" 2>/dev/null | grep -oE "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" | head -n 1 || echo "")
    fi

    if [ -n "$EMAIL" ]; then
        EMAIL_INFO="(✉️ $EMAIL)"
    else
        EMAIL_INFO="(⚪️ Пустой слот)"
    fi
    echo "👤 Активный профиль: $PROF_NAME $EMAIL_INFO"
else
    echo "👤 Активный профиль: 🏢 Рабочий (по умолчанию)"
fi

# Проверка привязки профиля
CLAUDE_SUPPORT="$HOME/Library/Application Support/Claude"
if [ -L "$CLAUDE_SUPPORT" ]; then
    TARGET=$(readlink "$CLAUDE_SUPPORT")
    echo "🔗 Symlink Application Support: $TARGET"
elif [ -d "$CLAUDE_SUPPORT" ]; then
    echo "⚠️ Application Support: папка (не symlink)"
fi

CLAUDE_JSON="$HOME/.claude.json"
if [ -L "$CLAUDE_JSON" ]; then
    TARGET_JSON=$(readlink "$CLAUDE_JSON")
    echo "🔗 Symlink ~/.claude.json: $TARGET_JSON"
elif [ -f "$CLAUDE_JSON" ]; then
    echo "⚠️ ~/.claude.json: файл (не symlink)"
fi

# 4. Статус повседневного VPN
if [ -z "${DEFAULT_VPN_NAME:-}" ] && [ -f "$DIR/guard-settings.json" ]; then
    DEFAULT_VPN_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("defaultVpnServiceName", ""))' "$DIR/guard-settings.json" 2>/dev/null || true)
fi
if [ -n "${DEFAULT_VPN_NAME:-}" ]; then
    VPN_STATUS=$(scutil --nc status "$DEFAULT_VPN_NAME" 2>/dev/null | head -n 1)
    echo "📶 $DEFAULT_VPN_NAME: ${VPN_STATUS:-Не найден}"
else
    echo "📶 Повседневный VPN: не настроен"
fi

# 5. Последние 10 строк лога
if [ -f "$DIR/guard.log" ]; then
    echo ""
    echo "=== Последние записи в логе ==="
    tail -n 10 "$DIR/guard.log"
fi
