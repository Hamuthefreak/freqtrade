#!/bin/bash
# Telegram alert when the bot has taken no new entry for more than three days.
#
# Reads the trade DB read-only and the bot/chat ids from the freqtrade config;
# never prints either. Sends at most one alert per 24h so a quiet fortnight
# cannot become a message storm. Run it from cron every few hours.
set -u

python3 - <<'PY'
import datetime
import json
import os
import sqlite3
import urllib.parse
import urllib.request

CFG = "/opt/freqtrade/user_data/config.json"
DB = "/opt/freqtrade/user_data/tradesv3.sqlite"
STATE = "/var/lib/hamu-idle-alert.ts"
DAYS = 3.0

try:
    conf = json.load(open(CFG))
except Exception as exc:
    print("cannot read config: %s" % exc)
    raise SystemExit(1)

tg = conf.get("telegram") or {}
token = tg.get("token")
chat = tg.get("chat_id")
if not tg.get("enabled") or not token or not chat:
    print("telegram disabled or unconfigured, nothing to do")
    raise SystemExit(0)

try:
    con = sqlite3.connect("file:" + DB + "?mode=ro", uri=True)
    row = con.execute("select max(open_date) from trades").fetchone()
except Exception as exc:
    print("db read failed: %s" % exc)
    raise SystemExit(1)

last = row[0] if row else None
if not last:
    print("no trades in the database yet")
    raise SystemExit(0)

last_dt = datetime.datetime.strptime(last.split(".")[0], "%Y-%m-%d %H:%M:%S")
age = (datetime.datetime.utcnow() - last_dt).total_seconds() / 86400.0
print("last entry %s UTC, age %.1f days" % (last_dt, age))

if age < DAYS:
    if os.path.exists(STATE):
        os.remove(STATE)
    print("younger than %.0f days, no alert" % DAYS)
    raise SystemExit(0)

now = datetime.datetime.utcnow()
if os.path.exists(STATE):
    try:
        sent = datetime.datetime.fromisoformat(open(STATE).read().strip())
    except Exception:
        sent = None
    if sent and (now - sent).total_seconds() < 86400:
        print("already alerted within 24h")
        raise SystemExit(0)

text = (
    "HamuBot is idle: no new entry for %.1f days (last one %s UTC).\n"
    "The bot is up and healthy, its entry gate simply has not fired.\n"
    "Dashboard: https://hamubot.taile5fc2c.ts.net/ui"
) % (age, last_dt.strftime("%Y-%m-%d %H:%M"))

data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
req = urllib.request.Request(
    "https://api.telegram.org/bot" + token + "/sendMessage", data=data
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        print("alert sent, http %s" % resp.status)
    with open(STATE, "w") as fh:
        fh.write(now.isoformat())
except Exception as exc:
    print("alert failed: %s" % exc)
    raise SystemExit(1)
PY
