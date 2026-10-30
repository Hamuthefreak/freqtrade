#!/usr/bin/env bash
#
# Makes sure the VM has a swapfile.
#
# Why: freqtrade loads pandas/numpy per pair and needs ~400-600 MB. On a 1 GB
# Oracle micro, LoadWave + PostgreSQL already take most of the RAM, so without
# swap the kernel kills the container while it starts and the bot never comes
# up. 2 GB of swap is slow but plenty for a dry run.
#
# Idempotent, and quiet when it cannot act (swap already on, no sudo, no disk).
set -uo pipefail

SWAPFILE=/swapfile
SIZE_MB=${SWAP_SIZE_MB:-2048}

if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
  echo "==> swap: already active ($SWAPFILE)"
  exit 0
fi

if ! sudo -n true 2>/dev/null; then
  echo "==> swap: no passwordless sudo, skipping (the bot may be OOM-killed)."
  exit 0
fi

AVAIL_MB=$(df --output=avail -m / | tail -1 | tr -d ' ')
if [ "${AVAIL_MB:-0}" -lt $((SIZE_MB + 1024)) ]; then
  echo "==> swap: only ${AVAIL_MB} MB free on /, skipping ${SIZE_MB} MB swapfile."
  exit 0
fi

echo "==> swap: creating ${SIZE_MB} MB swapfile (one time)"
if ! sudo -n fallocate -l "${SIZE_MB}M" "$SWAPFILE" 2>/dev/null; then
  sudo -n rm -f "$SWAPFILE"
  sudo -n dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=none
fi
sudo -n chmod 600 "$SWAPFILE"
sudo -n mkswap "$SWAPFILE" >/dev/null
sudo -n swapon "$SWAPFILE"

if ! grep -qs "^$SWAPFILE" /etc/fstab; then
  echo "$SWAPFILE none swap sw 0 0" | sudo -n tee -a /etc/fstab >/dev/null
fi

echo "==> swap: active"
swapon --show 2>/dev/null || true
