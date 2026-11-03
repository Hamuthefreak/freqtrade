#!/bin/sh
# Reach the dashboard from a phone that cannot install a VPN client or change
# its DNS: publish the existing tailnet HTTPS name over Tailscale Funnel, behind
# a password gate, so any browser gets a login box and nothing else.
#
# Tailscale Funnel is public. The gate is what makes that acceptable: the UI is
# Basic-auth protected, and /api is left to freqtrade's own password check
# because a browser can only send one Authorization header per request.
#
# Run as root on the bot host:  sudo sh public-dashboard.sh
# Undo (back to tailnet-only):  sudo tailscale funnel --https=443 off
set -e
DIR=/opt/freqtrade/ui-gate
mkdir -p "$DIR"

if [ -f "$DIR/pass.txt" ]; then
  PASS=$(cat "$DIR/pass.txt")
else
  PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20)
  printf '%s' "$PASS" > "$DIR/pass.txt"
fi
chmod 600 "$DIR/pass.txt"
# 644 because the nginx worker drops privileges and must read the hash.
printf 'hamu:%s\n' "$(openssl passwd -apr1 "$PASS")" > "$DIR/htpasswd"
chmod 644 "$DIR/htpasswd"

cat > "$DIR/nginx.conf" <<'CONF'
limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;

server {
    listen 127.0.0.1:8081;
    server_name _;
    client_max_body_size 8m;

    # FreqUI shell and its assets: browser-level password gate.
    location / {
        auth_basic "HamuBot";
        auth_basic_user_file /etc/nginx/auth/htpasswd;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }

    # API: freqtrade authenticates these itself, so the header passes through.
    location /api/ {
        limit_req zone=api burst=40 nodelay;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }
}
CONF

docker rm -f hamu-ui-gate >/dev/null 2>&1 || true
docker run -d --name hamu-ui-gate --restart always --network host \
  -v "$DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$DIR/htpasswd:/etc/nginx/auth/htpasswd:ro" \
  nginx:alpine >/dev/null
sleep 3

tailscale funnel --bg --https=443 http://127.0.0.1:8081
tailscale funnel status

AP=$(python3 -c "import json;c=json.load(open('/opt/freqtrade/user_data/config.json'))['api_server'];print(c['username']+':'+c['password'])")
echo "ui, no creds  : $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/ui)"
echo "ui, gate creds: $(curl -s -o /dev/null -w '%{http_code}' -u "hamu:$PASS" http://127.0.0.1:8081/ui)"
echo "api, api creds: $(curl -s -o /dev/null -w '%{http_code}' -u "$AP" http://127.0.0.1:8081/api/v1/show_config)"
echo "api, no creds : $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/api/v1/show_config)"

# The gate password has to reach the owner somehow, and it must not be pasted
# into a chat, so it goes to their own Telegram chat.
python3 - <<'PY'
import json, urllib.parse, urllib.request
cfg = json.load(open('/opt/freqtrade/user_data/config.json'))
pw = open('/opt/freqtrade/ui-gate/pass.txt').read().strip()
api = cfg['api_server']
text = ("HamuBot dashboard, reachable from any phone with no VPN and no DNS change:\n"
        "https://hamubot.taile5fc2c.ts.net/ui\n\n"
        "Login 1, the browser's own box:        hamu / " + pw + "\n"
        "Login 2, the FreqUI page after that:   " + api['username'] + " / " + api['password'] + "\n\n"
        "Keep this private and delete it once you are in. Dry run: no real money moves.")
data = urllib.parse.urlencode({'chat_id': cfg['telegram']['chat_id'], 'text': text}).encode()
req = urllib.request.Request('https://api.telegram.org/bot' + cfg['telegram']['token'] + '/sendMessage', data)
print('credentials sent, telegram http', urllib.request.urlopen(req, timeout=25).status)
PY
