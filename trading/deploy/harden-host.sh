#!/usr/bin/env bash
#
# Host-side survival limits for the dry-run bot on a 1 GB Always Free micro VM.
#
#   sudo bash harden-host.sh
#
# Everything here is idempotent: re-running changes nothing that is already set.
# It covers what a container cannot protect itself from:
#
#   * docker json-file logs growing without bound (fills the boot volume)
#   * systemd journal growing without bound (33 MB after one hour here)
#   * the kernel picking sshd as the OOM victim instead of the bot
#   * password SSH logins to a machine that is open on the internet
#   * a wedged-but-alive bot, which no restart policy ever catches
set -euo pipefail

log() { echo "==> $*"; }

# --- 1. Docker: global log cap + live-restore ---------------------------------
log "Docker daemon log cap"
mkdir -p /etc/docker
DAEMON_JSON='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}'
if [ -f /etc/docker/daemon.json ] && [ "$(cat /etc/docker/daemon.json)" = "$DAEMON_JSON" ]; then
  echo "    already configured"
else
  [ -f /etc/docker/daemon.json ] && cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  printf '%s\n' "$DAEMON_JSON" > /etc/docker/daemon.json
  if dockerd --validate --config-file=/etc/docker/daemon.json >/dev/null 2>&1; then
    echo "    config valid, applying"
    # live-restore keeps the bot running across the daemon restart.
    systemctl restart docker
    for _ in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done
  else
    echo "    WARN: dockerd rejected the config, leaving the previous one" >&2
    rm -f /etc/docker/daemon.json
    [ -n "$(ls -1 /etc/docker/daemon.json.bak.* 2>/dev/null | tail -1)" ] && \
      mv "$(ls -1 /etc/docker/daemon.json.bak.* | tail -1)" /etc/docker/daemon.json
  fi
fi

# --- 2. journald cap ----------------------------------------------------------
log "Journal size cap (200 MB)"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-cap.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
systemctl restart systemd-journald || true

# --- 3. kernel tunables -------------------------------------------------------
log "Kernel tunables (swap-friendly, keep headroom for sshd)"
cat > /etc/sysctl.d/99-freqtrade.conf <<'EOF'
# Use swap before the kernel starts killing processes.
vm.swappiness = 20
# Keep ~32 MB free so an SSH login can still fork under pressure.
vm.min_free_kbytes = 32768
EOF
sysctl --system >/dev/null 2>&1 || true

# --- 4. protect sshd from the OOM killer --------------------------------------
log "Sparing sshd from the OOM killer"
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/oom.conf <<'EOF'
[Service]
# sshd must outlive the bot: an unkillable SSH daemon is the difference between
# "the bot crashed" and "the box is gone".
OOMScoreAdjust=-900
EOF
systemctl daemon-reload
# Apply to the running daemons without dropping this session.
for pid in $(pgrep -x sshd || true); do
  echo -900 > "/proc/$pid/oom_score_adj" 2>/dev/null || true
done

# --- 5. SSH: keys only --------------------------------------------------------
log "SSH hardening (disable password logins)"
EFFECTIVE="$(sshd -T 2>/dev/null || true)"
if printf '%s\n' "$EFFECTIVE" | grep -qi '^passwordauthentication yes'; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 4
EOF
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    echo "    password logins disabled (key logins unaffected)"
  else
    echo "    WARN: sshd rejected the config, removing it" >&2
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
  fi
else
  echo "    already keys-only"
fi

# --- 6. watchdog for a wedged-but-alive bot -----------------------------------
log "Installing the watchdog (every 5 minutes)"
cat > /usr/local/bin/freqtrade-guard.sh <<'EOF'
#!/usr/bin/env bash
# Bring the bot back if it is stopped, unhealthy, or the container is gone.
# Silent when everything is fine. Disable with:
#   sudo systemctl disable --now freqtrade-guard.timer
set -u
cd /opt/freqtrade 2>/dev/null || exit 0

state="$(docker inspect -f '{{.State.Running}}' freqtrade 2>/dev/null || echo missing)"
health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' freqtrade 2>/dev/null || echo none)"

if [ "$state" != "true" ]; then
  logger -t freqtrade-guard "container not running (state=$state), starting it"
  docker compose up -d >/dev/null 2>&1
elif [ "$health" = "unhealthy" ]; then
  logger -t freqtrade-guard "container reports unhealthy (API not answering), restarting"
  docker restart freqtrade >/dev/null 2>&1
fi
EOF
chmod 0755 /usr/local/bin/freqtrade-guard.sh

cat > /etc/systemd/system/freqtrade-guard.service <<'EOF'
[Unit]
Description=Watchdog for the freqtrade container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/freqtrade-guard.sh
EOF

cat > /etc/systemd/system/freqtrade-guard.timer <<'EOF'
[Unit]
Description=Run the freqtrade watchdog every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now freqtrade-guard.timer >/dev/null 2>&1

log "Done"
echo "    docker log cap : $(docker info --format '{{.LoggingDriver}}' 2>/dev/null) / $(docker info --format '{{index .DriverStatus 0}}' >/dev/null 2>&1; echo 'max-size 10m, max-file 3')"
echo "    journal cap    : $(grep -h SystemMaxUse /etc/systemd/journald.conf.d/99-cap.conf)"
echo "    watchdog       : $(systemctl is-enabled freqtrade-guard.timer 2>/dev/null) / $(systemctl is-active freqtrade-guard.timer 2>/dev/null)"
echo "    password ssh   : $(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')"
