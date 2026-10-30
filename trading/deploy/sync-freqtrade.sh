#!/usr/bin/env bash
#
# Runs after every LoadWave deploy (GitHub Actions -> SSH -> here).
#
# Keeps the bot's compose file current and restarts the container if the image
# moved. It deliberately does NOT overwrite /opt/freqtrade/user_data/config.json:
# that live file holds the generated web credentials, your pair list and the
# dry_run / live switch. Change it on the server (or delete it to re-seed).
#
# Never blocks a LoadWave deploy: when nothing can be done it exits 0.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/opt/freqtrade"
LIVE_CONFIG="$APP_DIR/user_data/config.json"

# First run, or docker not installed yet: the installer handles both (it also
# bootstraps docker itself when the deploy user has passwordless sudo).
if ! command -v docker >/dev/null 2>&1 || [ ! -f "$LIVE_CONFIG" ]; then
  echo "==> freqtrade: not installed yet - running the installer."
  bash "$SRC_DIR/deploy/install-freqtrade.sh"
  exit $?
fi

DC="docker"
if ! docker info >/dev/null 2>&1; then
  DC="sudo -n docker"
  if ! $DC info >/dev/null 2>&1; then
    echo "==> freqtrade: no docker permission for this user - skipping."
    exit 0
  fi
fi

# A 1 GB VM cannot hold LoadWave + PostgreSQL + the bot in RAM alone.
bash "$SRC_DIR/deploy/ensure-swap.sh" || true

echo "==> freqtrade: syncing compose file"
mkdir -p "$APP_DIR/user_data/strategies"
install -m 0644 "$SRC_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"

# Pick up strategy files added to the repo, without clobbering local edits.
if [ -d "$SRC_DIR/user_data/strategies" ]; then
  cp -n "$SRC_DIR"/user_data/strategies/* "$APP_DIR/user_data/strategies/" 2>/dev/null || true
fi

cd "$APP_DIR"
$DC compose pull --quiet || echo "WARN: image pull failed - keeping the running image."
$DC compose up -d

echo "==> freqtrade: waiting for the API (up to 4 min on a small VM)"
healthy=""
for _ in $(seq 1 80); do
  if curl -fsS http://127.0.0.1:8080/api/v1/ping >/dev/null 2>&1; then
    healthy="yes"
    break
  fi
  sleep 3
done

if [ -z "$healthy" ]; then
  echo "ERROR: the bot's API is not answering after restart." >&2
  free -m >&2 || true
  $DC compose logs --tail 40 >&2 || true
  exit 1
fi

echo "==> freqtrade: healthy"
