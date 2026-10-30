#!/usr/bin/env bash
#
# Stops LoadWave completely and frees the VM for the trading bot.
#
# NOTHING IS DELETED. The code stays in /opt/loadboard, the PostgreSQL data
# files stay in /var/lib/postgresql, nginx configs stay in /etc/nginx, and the
# systemd unit stays on disk. It is only stopped and disabled so it does not
# come back on the next reboot.
#
# Undo with: bash trading/deploy/resume-loadwave.sh
#
# Run on the VM (as the deploy user, which has passwordless sudo):
#   bash /opt/loadboard/trading/deploy/pause-loadwave.sh
set -uo pipefail

SUDO="sudo -n"
if ! $SUDO true 2>/dev/null; then
  echo "ERROR: this script needs passwordless sudo on the VM." >&2
  exit 1
fi

show_mem() {
  echo "---- memory ----"
  free -m | sed -n '1,3p'
  echo "----------------"
}

echo "==> Before"
show_mem

# Stop in dependency order: the API first, then the web server that fronts it,
# then the database it talks to. Disable so a reboot does not undo this.
for unit in loadboard nginx postgresql; do
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${unit}\.service"; then
    echo "==> Stopping and disabling $unit"
    $SUDO systemctl stop "$unit" 2>/dev/null
    $SUDO systemctl disable "$unit" >/dev/null 2>&1
  else
    echo "==> $unit: no such service here, skipping"
  fi
done

# Anything else LoadWave left behind in docker (not used today, harmless if not).
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi loadboard; then
    echo "==> Stopping leftover loadboard containers"
    docker ps -q --filter "name=loadboard" | xargs -r docker stop >/dev/null 2>&1 || true
  fi
fi

echo
echo "==> After"
show_mem
echo
echo "LoadWave is stopped. Files are untouched in /opt/loadboard."
echo "It will NOT come back after a reboot until you run resume-loadwave.sh."
echo "The site is offline now (nginx is down), which is expected."
