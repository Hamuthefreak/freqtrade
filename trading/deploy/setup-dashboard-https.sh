#!/usr/bin/env bash
# Put the HamuBot dashboard on your own tailnet with a real Let's Encrypt cert.
#
#   sudo bash trading/deploy/setup-dashboard-https.sh
#
# Access model: `tailscale serve`, NOT `tailscale funnel`. Serve publishes the
# dashboard to devices signed in to your tailnet only; Funnel publishes it to
# the whole internet on the same port, which is exactly what we do not want for
# a trading control plane. freqtrade's docs say not to expose this API publicly,
# and Tailscale keeps that promise: no inbound ports, no public URL, no CORS.
set -euo pipefail

TS_HOSTNAME=${TS_HOSTNAME:-hamubot}
PORT=${DASHBOARD_PORT:-8080}

if ! command -v tailscale >/dev/null 2>&1; then
  echo "==> installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

if ! tailscale status >/dev/null 2>&1; then
  cat <<EOF
This machine is not signed in to a tailnet yet. From an SSH session run:

  sudo tailscale up --hostname=$TS_HOSTNAME --accept-dns=false

It prints a https://login.tailscale.com/... URL; open it in any browser, sign in
(or create the free Personal account), and approve the node. Then re-run this
script. Add --accept-dns=false is deliberate: the bot should not get its DNS
rewritten, it only needs the tunnel outbound.

Before the certificate can be issued, the tailnet also needs MagicDNS and HTTPS
certificates enabled (admin console -> DNS). The serve command below will print
a consent link if they are still off.
EOF
  exit 0
fi

# Prove the dashboard answers locally before advertising it.
if ! curl -fsS -m 5 "http://127.0.0.1:$PORT/api/v1/ping" >/dev/null 2>&1; then
  echo "ERROR: nothing answering on 127.0.0.1:$PORT — is the bot running?" >&2
  exit 1
fi
echo "==> local API answers on 127.0.0.1:$PORT"

echo "==> publishing to the tailnet over HTTPS"
tailscale serve --bg "$PORT"
tailscale serve status || true

FQDN=$(tailscale status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//; s/\.$//')
echo
if [ -n "$FQDN" ]; then
  echo "Dashboard: https://$FQDN/ui"
  echo "(sign in with the api_server username and password from config.json)"
else
  echo "Dashboard: https://$TS_HOSTNAME.<your-tailnet>.ts.net/ui"
fi
