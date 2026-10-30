#!/usr/bin/env bash
#
# Connect the dry-run bot to Telegram, so entries/exits and a daily summary
# arrive on your phone.
#
#   bash set-telegram.sh <bot-token> [chat-id]
#
# Getting a token (one time, on your phone):
#   1. In Telegram, message @BotFather  ->  /newbot  ->  pick any name.
#      BotFather replies with a token like 123456789:AAExampleExampleExample.
#   2. Open your new bot (BotFather gives you the link) and send it "hi".
#      A bot cannot message you until you have messaged it first.
#   3. Run this script with just the token - it reads your chat id from
#      getUpdates. Pass a chat id as the second argument to skip that.
#
# Safe to re-run: it rewrites only the telegram block and restarts the bot.
set -euo pipefail

TOKEN="${1:-}"
CHAT_ID="${2:-}"
APP_DIR="/opt/freqtrade"
CONFIG="$APP_DIR/user_data/config.json"

if [ -z "$TOKEN" ]; then
  echo "usage: bash set-telegram.sh <bot-token> [chat-id]" >&2
  exit 2
fi
if ! printf '%s' "$TOKEN" | grep -Eq '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$'; then
  echo "ERROR: that does not look like a bot token (expected 123456789:AA...)" >&2
  exit 2
fi
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG not found - run install-freqtrade.sh first." >&2
  exit 1
fi

API="https://api.telegram.org/bot$TOKEN"

echo "==> Validating the token (getMe)"
ME="$(curl -fsS --max-time 20 "$API/getMe")" || {
  echo "ERROR: Telegram rejected the token. Response: $ME" >&2
  exit 1
}
BOT="$(printf '%s' "$ME" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["username"])')"
echo "    bot: @$BOT"

if [ -z "$CHAT_ID" ]; then
  echo "==> Finding your chat id (send your bot a message first)"
  CHAT_ID="$(curl -fsS --max-time 20 "$API/getUpdates" | python3 -c '
import json, sys
updates = json.load(sys.stdin).get("result", [])
ids = []
for u in updates:
    msg = u.get("message") or u.get("edited_message") or {}
    chat = msg.get("chat") or {}
    if chat.get("id") is not None:
        ids.append(str(chat["id"]))
print(ids[-1] if ids else "")
')"
  if [ -z "$CHAT_ID" ]; then
    echo "ERROR: no messages seen by the bot yet." >&2
    echo "       Open Telegram, send @$BOT any message, then run this again." >&2
    echo "       (Or pass your chat id as the second argument.)" >&2
    exit 1
  fi
fi
echo "    chat id: $CHAT_ID"

echo "==> Writing the telegram block into $CONFIG"
sudo python3 - "$CONFIG" "$TOKEN" "$CHAT_ID" <<'PY'
import json
import sys

path, token, chat_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as fh:
    cfg = json.load(fh)

cfg["telegram"] = {
    "enabled": True,
    "token": token,
    "chat_id": chat_id,
    "notification_settings": {
        "status": "on",
        "warning": "on",
        "startup": "on",
        "entry": "on",
        "entry_fill": "on",
        "entry_cancel": "on",
        "exit": "on",
        "exit_fill": "on",
        "exit_cancel": "on",
        "protection_trigger": "on",
        "balance": "on",
        "trade": "on",
        # Hour (UTC) for the daily summary. 6 UTC ~ 02:00 in Montreal.
        "daily": 6,
    },
}

with open(path, "w") as fh:
    json.dump(cfg, fh, indent=4)
    fh.write("\n")
PY

# The bot runs as the image user (uid 1000); keep the config readable by it.
sudo chown 1000:1000 "$CONFIG"
sudo chmod 600 "$CONFIG"

echo "==> Restarting the bot"
cd "$APP_DIR"
sudo docker compose up -d --force-recreate >/dev/null

echo "==> Waiting for the API"
for _ in $(seq 1 40); do
  if curl -fsS -m 3 http://127.0.0.1:8080/api/v1/ping 2>/dev/null | grep -q pong; then
    echo "    API is up"
    break
  fi
  sleep 3
done

echo "==> Sending a test message to your chat"
curl -fsS --max-time 20 \
  --data-urlencode "chat_id=$CHAT_ID" \
  --data-urlencode "text=freqtrade dry run is connected. You will get entry/exit alerts and a daily summary here." \
  "$API/sendMessage" >/dev/null && echo "    delivered" || {
    echo "WARN: the test message was not delivered. Check that you started a chat with @$BOT." >&2
  }

echo
echo "Done. In Telegram you can now use /status, /balance, /profit, /daily, /stopbuy."
echo "To turn it off again: set \"telegram\":{\"enabled\": false ...} in $CONFIG and restart."
