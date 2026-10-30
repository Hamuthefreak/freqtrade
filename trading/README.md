# trading — the bot that runs next to LoadWave

This folder adds a crypto trading bot side-car to the same Oracle VM that serves
LoadWave. It is **dry run by default**: real market data, fake money, nothing can
be lost.

## Why it lives in its own folder

`/opt/loadboard` stays exactly as it is, so the existing deploy chain
(`auto-deploy.sh`, systemd, nginx, Prisma migrations) keeps working untouched.
The bot is a separate service in `/opt/freqtrade`, driven by its own
`docker-compose.yml`.

The bot's **source code is not copied to the VM** — the official
`freqtradeorg/freqtrade` image already contains it. Only the config, strategies
and database live in `user_data/`, which is what actually differs per
deployment. Copying ~100k lines of Python onto a small VM would only slow
deploys and add nothing.

## One-time install (on the VM)

```bash
# Docker, if this VM does not have it yet
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"      # log out / back in

# then
bash /opt/loadboard/trading/deploy/install-freqtrade.sh
```

The script checks free RAM, seeds `/opt/freqtrade/user_data/config.json`,
generates the web-UI password, pulls the image, starts the container and waits
until the API answers.

## Every push after that

`.github/workflows/deploy.yml` deploys LoadWave, then runs
`trading/deploy/sync-freqtrade.sh` on the VM. That step:

- skips silently if Docker is missing (never fails your site deploy),
- refreshes `docker-compose.yml` and any new strategy files,
- pulls the image and restarts the bot only if needed,
- refuses to touch your live `config.json`.

## Watching it

Port 8080 is bound to `127.0.0.1` only. From your laptop:

```bash
ssh -N -L 8080:127.0.0.1:8080 ubuntu@<vm-ip>
# then open http://127.0.0.1:8080  (user: freqtrader, password: generated at install)
```

## Telegram (phone control + alerts)

Everything about a phone workflow runs through a bot you own. On the VM:

```bash
# once: message @BotFather -> /newbot -> copy the token, then message your new bot "hi"
bash /opt/freqtrade-src/trading/deploy/set-telegram.sh <bot-token>
# or, if you already know your chat id:
bash /opt/freqtrade-src/trading/deploy/set-telegram.sh <bot-token> <chat-id>
```

The script validates the token with `getMe`, discovers your chat id from
`getUpdates`, writes the `telegram` block into `user_data/config.json`, restarts
the container, waits for the API and sends a test message. It is safe to re-run.

What lands on your phone: entry/exit fills and cancellations, protection
triggers, startup/status/warnings, balance and a daily summary (`daily: 6`, i.e.
06:00 UTC). Commands: `/status`, `/balance`, `/profit`, `/daily`, `/stopbuy`,
`/reload_config`.

`set-telegram.sh` needs no SSH if you use the **VM shell (manual)** workflow in
`.github/workflows/vm-shell.yml`: Actions -> VM shell -> Run workflow, and put
the command in the `command` input. Only accounts with write access can start
it, and the token never ends up in a chat log - it goes from BotFather straight
into the VM's config file.

## Day-to-day commands (on the VM)

```bash
cd /opt/freqtrade
docker compose ps
docker compose logs -f --tail 100
docker compose restart
docker compose down          # stop trading entirely
```

## Changing settings

Edit `/opt/freqtrade/user_data/config.json` directly, then
`docker compose restart`. The repo copy is only a template used at first install,
so edits made in the UI or on the server survive deploys.

To go live later: set `"dry_run": false` and add exchange keys with **trade-only
permission, withdrawals disabled**. Do that only after weeks of dry-run results
you understand.

## RAM check — read this once

LoadWave (Node + PostgreSQL) plus the bot needs headroom. freqtrade loads
pandas/numpy per pair; on a 1 GB AMD micro instance the OOM killer will take it
out. `install-freqtrade.sh` prints available RAM and warns below ~900 MB. The
Ampere A1 (free tier) shape is fine; the arm64 image is published.
