#!/usr/bin/env bash
#
# One-time install of the trading bot (freqtrade, DRY RUN) on a dedicated VM.
#
# Run ON the server, as the deploy user:
#   bash /home/ubuntu/freqtrade-src/trading/deploy/install-freqtrade.sh
#
# Safe to re-run: it keeps an existing live config (and its generated web
# credentials) untouched. When Docker is missing it installs it, provided the
# deploy user has passwordless sudo (the default for "ubuntu" on Oracle Cloud).
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../trading
APP_DIR="/opt/freqtrade"
LIVE_CONFIG="$APP_DIR/user_data/config.json"

echo "==> freqtrade installer (dry run)"

AVAIL_MB="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
CORES="$(nproc 2>/dev/null || echo '?')"
ARCH="$(uname -m)"
echo "    host: ${ARCH}, ${CORES} CPU, ${AVAIL_MB} MB RAM available"

# On a 1 GB box the bot runs with a hard 768 MB container cap (see
# docker-compose.yml) and needs swap to start: pandas/numpy alone are a few
# hundred MB. Without swap the kernel kills the container during startup.
if [ "${AVAIL_MB}" -lt 1500 ]; then
  echo "    low-memory host: expecting swap + the 768 MB container cap"
  bash "$SRC_DIR/deploy/ensure-swap.sh" || {
    echo "WARN: swap could not be created — the bot may be killed while starting." >&2
  }
fi

# --- Docker + compose plugin ------------------------------------------------
install_compose_plugin() {
  local arch dir=/usr/local/lib/docker/cli-plugins
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; return 1 ;;
  esac
  echo "==> Installing the docker compose plugin ($arch)"
  sudo -n mkdir -p "$dir"
  sudo -n curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" -o "$dir/docker-compose"
  sudo -n chmod +x "$dir/docker-compose"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if ! sudo -n true 2>/dev/null; then
      echo "==> docker is not installed and this user has no passwordless sudo." >&2
      echo "    Install it once, then re-run this script:" >&2
      echo "      sudo apt-get update && sudo apt-get install -y docker.io" >&2
      echo "      sudo systemctl enable --now docker" >&2
      echo "      sudo usermod -aG docker \"\$USER\"" >&2
      return 1
    fi
    echo "==> Installing docker.io (first run only, ~1 min)"
    sudo -n apt-get update -qq
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
    sudo -n systemctl enable --now docker >/dev/null 2>&1 || true
    sudo -n usermod -aG docker "$USER" >/dev/null 2>&1 || true
  fi
  if ! docker compose version >/dev/null 2>&1 && ! sudo -n docker compose version >/dev/null 2>&1; then
    install_compose_plugin || return 1
  fi
  return 0
}

if ! ensure_docker; then
  echo "==> Not installing the bot (docker unavailable)."
  exit 1
fi

# Prefer docker without sudo; fall back to non-interactive sudo when the CI user
# has no docker group membership yet (a group change needs a fresh login).
DC="docker"
if ! docker info >/dev/null 2>&1; then
  DC="sudo -n docker"
  if ! $DC info >/dev/null 2>&1; then
    echo "ERROR: no permission to talk to the docker daemon." >&2
    echo "       Fix: sudo usermod -aG docker \$USER  (then log out and back in)" >&2
    exit 1
  fi
fi

echo "==> Preparing $APP_DIR"
if ! mkdir -p "$APP_DIR/user_data/logs" "$APP_DIR/user_data/data" "$APP_DIR/user_data/strategies" 2>/dev/null; then
  echo "    (using sudo for $APP_DIR)"
  sudo -n mkdir -p "$APP_DIR/user_data/logs" "$APP_DIR/user_data/data" "$APP_DIR/user_data/strategies"
  sudo -n chown -R "$(id -u):$(id -g)" "$APP_DIR"
fi

install -m 0644 "$SRC_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"
if [ -d "$SRC_DIR/user_data/strategies" ]; then
  cp -n "$SRC_DIR"/user_data/strategies/* "$APP_DIR/user_data/strategies/" 2>/dev/null || true
fi

if [ ! -f "$LIVE_CONFIG" ]; then
  echo "==> Seeding config and generating web-UI credentials"
  install -m 0600 "$SRC_DIR/user_data/config.json" "$LIVE_CONFIG"
  python3 - "$LIVE_CONFIG" <<'PY'
import json, secrets, sys

path = sys.argv[1]
with open(path) as fh:
    cfg = json.load(fh)

api = cfg["api_server"]
api["jwt_secret_key"] = secrets.token_hex(32)
api["ws_token"] = secrets.token_urlsafe(24)
api["password"] = secrets.token_urlsafe(12)

with open(path, "w") as fh:
    json.dump(cfg, fh, indent=4)
    fh.write("\n")

print("    web UI login  ->  user: %s   password: %s" % (api["username"], api["password"]))
print("    (also stored in %s - change it there any time)" % path)
PY
else
  echo "==> Keeping existing live config: $LIVE_CONFIG"
fi

# The container runs as the image's own user (ftuser, uid 1000), while the files
# above are created by the deploy user (ubuntu, uid 1001) with mode 0600. Without
# this the bot starts and immediately dies with
#   PermissionError: [Errno 13] Permission denied: '/freqtrade/user_data/config.json'
CT_UID="$($DC run --rm --entrypoint id freqtradeorg/freqtrade:stable -u 2>/dev/null || echo 1000)"
case "$CT_UID" in
  ''|*[!0-9]*) CT_UID=1000 ;;
esac
echo "==> Aligning user_data ownership with the container user (uid $CT_UID)"
sudo -n chown -R "$CT_UID:$CT_UID" "$APP_DIR/user_data" 2>/dev/null || true

echo "==> Pulling the image (a few hundred MB on first run)"
cd "$APP_DIR"
$DC compose pull

echo "==> Starting the bot"
$DC compose up -d

echo "==> Waiting for the API to answer on 127.0.0.1:8080 (up to ~3 min)"
healthy=""
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8080/api/v1/ping >/dev/null 2>&1; then
    healthy="yes"
    break
  fi
  sleep 3
done

if [ -z "$healthy" ]; then
  echo "WARN: the API did not answer yet. Last log lines:" >&2
  $DC compose logs --tail 40 || true
  echo "--- container state ---" >&2
  $DC compose ps || true
  free -m || true
  exit 1
fi

echo ""
echo "OK - the bot is running in DRY RUN (fake money, live prices)."
echo "View the UI from your laptop (never expose port 8080 publicly):"
echo ""
echo "  ssh -N -L 8080:127.0.0.1:8080 <user>@<vm-ip>"
echo "  then open http://127.0.0.1:8080"
echo ""
echo "Logs:    cd $APP_DIR && $DC compose logs -f"
echo "Restart: cd $APP_DIR && $DC compose restart"
echo "Stop:    cd $APP_DIR && $DC compose down"
