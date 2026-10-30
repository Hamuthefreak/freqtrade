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

## Limits and self-healing

A 1 GB Always Free micro is a hostile place to run a bot, so the failure modes
are closed off explicitly rather than hoped away:

| Risk | Limit |
| --- | --- |
| OOM killer takes sshd, box unreachable | 768 MB container cap, 1.5 GB swap, `oom_score_adj: 500` on the bot, `OOMScoreAdjust=-900` on sshd |
| Restart loop starves the host | `restart: on-failure:3` (gives up instead of looping) |
| docker json-file log fills the disk | `max-size: 10m`, `max-file: 3`, globally in `/etc/docker/daemon.json` |
| systemd journal fills the disk | `SystemMaxUse=200M` |
| Runaway CPU starves the shell | `cpus: "0.9"` |
| Thread/fork leak exhausts pids | `pids_limit: 200` |
| Bot alive but wedged (never "crashes") | API healthcheck + `freqtrade-guard.timer` every 5 min |

```bash
sudo bash /opt/freqtrade-src/trading/deploy/harden-host.sh   # idempotent
```

The watchdog resurrects a stopped or unhealthy container within 5 minutes and
logs to the journal (`journalctl -t freqtrade-guard`). It also means a deliberate
`docker compose down` gets undone — disable it with
`sudo systemctl disable --now freqtrade-guard.timer` before stopping the bot for
good.

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

## Claiming the free Arm instance (optional)

Oracle's Always Free Ampere A1 shape is usually "out of host capacity", so
`claim-a1.sh` runs from a five-minute systemd timer, tries one launch, and logs
the result. It stops itself the moment an instance exists, is hard-coded to a
single `VM.Standard.A1.Flex` at 1 OCPU / 6 GB, and has no other shape paths, so
it cannot create anything billable.

Setup, done once:

1. A key pair already exists on the VM at `/root/.oci/oci_api_key.pem` (mode
   600); only its public half ever leaves the box. Its fingerprint is
   `openssl rsa -pubout -outform DER -in /root/.oci/oci_api_key.pem | openssl md5 -c`.
2. OCI console: profile menu, User settings, API keys, Add API key, Paste public
   key. Paste `/root/.oci/oci_api_key_public.pem`. Never paste the private key.
3. Collect four values that are identifiers rather than secrets: the tenancy
   OCID, the user OCID, the region identifier, and the subnet OCID of the
   existing VCN.
4. Write `/root/.oci/config` (chmod 600) with `user`, `fingerprint`, `tenancy`,
   `region` and `key_file=/root/.oci/oci_api_key.pem`.
5. Write `/etc/oci-claim.conf` (chmod 600) with `COMPARTMENT_OCID` (the tenancy
   OCID works as root compartment), `AVAILABILITY_DOMAIN`, `SUBNET_OCID`,
   `IMAGE_OCID` (the aarch64 Ubuntu image for the region) and
   `SSH_PUBKEY_FILE=/home/ubuntu/.ssh/authorized_keys`.
6. `systemctl enable --now oci-claim-a1.timer`, then watch
   `/var/log/oci-claim-a1.log`.

Never upgrade the tenancy to Pay As You Go. Capacity beyond the Always Free Arm
allowance is billed, which is why this script pins the size and the count.

## The strategy that is actually running

`NASOSv4Wide` (a 4-line subclass of Foxel05's `NASOSv4`), spot, 5m, long only,
run from `user_data/strategies/NASOSv4Wide.py` via `--strategy NASOSv4Wide` in
the compose file. It is NASOSv4 with one rule removed — the `EWO > 2.4` trend
gate — because that gate made the strategy fire zero times in a week. See
"Tuning for trade frequency" below for the measurements behind that.

Fourteen pairs, not two: `BTC, ETH, SOL, DOGE, XRP, ADA, LINK, AVAX, INJ, NEAR,
ARB, APT, OP, TRX` against USDT, with `max_open_trades: 4` (400 USDT maximum
exposure of the 1000 dry wallet). The pair list is part of the strategy choice,
not an afterthought — the strategy trades liquid alts, not BTC/ETH.

Parameters come from the strategy file and are mirrored in `config.json`
(config values win in freqtrade): `stoploss -0.15`, ROI disabled
(`{"0": 10.0}`), trailing stop `0.1%` once `1.6%` in profit. It exits with a
trailing stop rather than a fixed target, so trades last hours, not minutes.

### Why this one, measured

Every candidate was backtested on this box with the same account
(100 USDT stake, 1000 wallet, 2 open trades) over 240 days of 5m Binance data:

| strategy | trades | profit | max DD | notes |
|---|---|---|---|---|
| **NASOSv4** | **15** | **+2.86%** | **0.00%** | all 15 winners, ~23h hold |
| ElliotV5_SMA | 9 | +0.79% | 0.44% | |
| DS_BNC_EV1E_5m | 3 | +0.41% | 0.00% | |
| E0V1E | 1 | +0.18% | 0.00% | |
| WolfBreakout_Pullback | 1 | 0.00% | 0.00% | daily timeframe |
| NotAnotherSMAOffsetStrategyHO | 0 | 0.00% | 0.00% | league #1, never fires here |
| DS_SOS_5m | 0 | 0.00% | 0.00% | |

The famous "best" strategies on the Freqle league (33 pairs, 2022–2024) are
alt-coin dip buyers: `NotAnotherSMAOffsetStrategyHO` needs price 3.4% below its
16-EMA on a 5-minute chart, which BTC/ETH did **zero** times in 26,122 candles.
NASOSv4 is the only candidate that fires often enough to be worth running, and it
trades alts, not BTC/ETH — hence the eight-pair list.

### Tuning for trade frequency

The shipped NASOSv4 settings produced **zero signals in 7 days** across 20 liquid
pairs (needs a 1.6% dip below the 8-EMA *and* `EWO > 2.4`), so the bot would sit
idle for weeks. Everything below was backtested on the same 14 pairs, last 30
days, 4 open-trade slots:

| variant | change | trades | profit | max DD | verdict |
|---|---|---|---|---|---|
| `NASOSv4` | as shipped | 0 | — | — | never fires |
| `NASOSv4FastA` | dip 0.5%, EWO > 0 | 67 | −5.46% | 8.5% | trades, loses |
| `NASOSv4FastB` | dip 1%, EWO > −2 | 68 | −8.90% | 11.2% | worse |
| `NASOSv4FastC` | dip 0.1%, EWO > 1 | 84 | −10.02% | 11.5% | worse |
| `NASOSv4T1`–`T4` | fast entries, tighter stops/TP | 214–339 | −8% to −10% | up to 13% | exits are not the problem |
| **`NASOSv4Wide`** | deep dip kept, EWO gate dropped | **31** | **+0.76%** | **3.0%** | **deployed** |
| `NASOSv4WideTight` | same entry, tight stop | 39 | −0.51% | 1.9% | worse |

Shallow dips have no edge after 0.1%/side fees; the deep dip does. `NASOSv4Wide`
is the only variant that both trades about once a day and stays positive.

`force_entry_enable` is `true` so a dry-run entry can be placed through the API
(loopback only, behind the SSH tunnel). It has no effect on normal signal-driven
entries.

### Re-running the comparison

```bash
# candidates live outside user_data so the live bot cannot load them by accident
sudo docker run --rm --memory 900m --cpus 1 \
  -v /opt/freqtrade/user_data:/freqtrade/user_data \
  -v /opt/freqtrade/candidates:/freqtrade/candidates:ro \
  freqtradeorg/freqtrade:stable backtesting --strategy NASOSv4 \
  --strategy-path /freqtrade/candidates \
  --config /freqtrade/user_data/backtest_alts.json --timerange 20260301-
```

`user_data/backtest.json` and `backtest_alts.json` carry no stoploss/ROI on
purpose, so each strategy is judged with its own risk settings instead of the
live config's.
