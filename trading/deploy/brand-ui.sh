#!/usr/bin/env bash
# Rebrand the FreqUI dashboard that freqtrade serves at /ui.
#
#   sudo bash trading/deploy/brand-ui.sh          # on the VM
#   IMAGE=freqtradeorg/freqtrade:2026.9 BOT_NAME=HamuBot sudo -E bash ...
#
# Why a copy on the host instead of patching inside the container: anything
# written into a running container is lost on the next `docker compose up`,
# and the image's own copy would come back unbranded. docker-compose.yml mounts
# ./ui read-only over the image's UI directory, so this script only has to keep
# that host directory correct.
#
# The source is a throwaway container of the image, NOT the running one: the
# running container already has ./ui mounted over that path, so copying from it
# would just re-copy our own patched files.
#
# Files are updated in place (rsync, or cp fallback). The directory itself is
# never replaced, because a bind mount follows the directory inode — swapping it
# would silently break the UI of the running container.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/freqtrade}
IMAGE=${IMAGE:-freqtradeorg/freqtrade:stable}
BOT_NAME=${BOT_NAME:-HamuBot}
UI_DIR="$APP_DIR/ui"
STAGE="$APP_DIR/.ui-staging"
UI_PATH=/freqtrade/freqtrade/rpc/api_server/ui/installed

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: the UI dir is root-owned" >&2; exit 1; }

echo "==> Extracting the shipped UI from $IMAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"
docker run --rm --entrypoint sh "$IMAGE" -c "tar -C $UI_PATH -cf - ." | tar -C "$STAGE" -xf -

if [ ! -f "$STAGE/index.html" ]; then
  echo "ERROR: $IMAGE does not contain a FreqUI build at $UI_PATH" >&2
  exit 1
fi

echo "==> Renaming FreqUI -> $BOT_NAME"
# Same length is not required, but the strings replaced here are display text
# only (page title, settings heading, no-JS notice). Nothing functional.
find "$STAGE" -maxdepth 1 -name 'index.html' -exec sed -i "s/FreqUI/$BOT_NAME/g" {} +
find "$STAGE/assets" -name '*.js' -exec sed -i "s/FreqUI/$BOT_NAME/g" {} +

echo "==> Publishing into $UI_DIR"
mkdir -p "$UI_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$STAGE/" "$UI_DIR/"
else
  # cp cannot delete files that a newer UI dropped, so clear old assets first.
  rm -rf "$UI_DIR/assets"
  cp -a "$STAGE/." "$UI_DIR/"
fi
chown -R 1000:1000 "$UI_DIR"
rm -rf "$STAGE"

grep -q "<title>$BOT_NAME</title>" "$UI_DIR/index.html" \
  && echo "    title is now: $(grep -o "<title>[^<]*</title>" "$UI_DIR/index.html")" \
  || { echo "WARN: title not updated, check the sed step" >&2; exit 1; }

echo "==> Restarting the bot so the UI is served from the new files"
if [ "${SKIP_RESTART:-0}" = "1" ]; then
  echo "    skipped (SKIP_RESTART=1)"
else
  ( cd "$APP_DIR" && docker compose up -d --force-recreate >/dev/null )
  for _ in $(seq 1 40); do
    curl -fsS -m 3 http://127.0.0.1:8080/api/v1/ping 2>/dev/null | grep -q pong && { echo "    API is up"; break; }
    sleep 3
  done
fi
echo "Done. Dashboard: http://127.0.0.1:8080/ui (through an SSH tunnel)."
