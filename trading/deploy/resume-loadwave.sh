#!/usr/bin/env bash
#
# Undoes pause-loadwave.sh: brings LoadWave back exactly as it was.
#
# Starts in dependency order (database -> API -> nginx), re-enables the units so
# they survive reboots, then checks the API answers on localhost:4000.
#
# Run on the VM:
#   bash /opt/loadboard/trading/deploy/resume-loadwave.sh
set -uo pipefail

SUDO="sudo -n"
if ! $SUDO true 2>/dev/null; then
  echo "ERROR: this script needs passwordless sudo on the VM." >&2
  exit 1
fi

for unit in postgresql loadboard nginx; do
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${unit}\.service"; then
    echo "==> Enabling and starting $unit"
    $SUDO systemctl enable "$unit" >/dev/null 2>&1
    $SUDO systemctl start "$unit" 2>/dev/null || $SUDO systemctl restart "$unit" 2>/dev/null
  else
    echo "==> $unit: no such service here, skipping"
  fi
done

echo "==> Waiting for the API on 127.0.0.1:4000"
healthy=""
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:4000/health >/dev/null 2>&1 \
     || curl -fsS http://127.0.0.1:4000/ >/dev/null 2>&1; then
    healthy="yes"
    break
  fi
  sleep 3
done

if [ -z "$healthy" ]; then
  echo "WARN: the API is not answering yet; check: sudo journalctl -u loadboard -n 50 --no-pager" >&2
  exit 1
fi

echo "==> LoadWave is back up."
echo "---- memory ----"
free -m | sed -n '1,3p'
echo "----------------"
echo "If the trading bot is still running it now shares the VM again — expect"
echo "memory pressure. Pause LoadWave again when you want the bot to have it all."
