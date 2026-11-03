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

## Watching it (the HamuBot dashboard)

freqtrade ships FreqUI inside its image and serves it from the same port as the
API, under `/ui`. Port 8080 is bound to `127.0.0.1` only, so from your laptop:

```bash
ssh -N -L 8080:127.0.0.1:8080 ubuntu@<vm-ip>
# then open http://127.0.0.1:8080/ui
```

Log in with the `api_server` username and password from the VM's `config.json`:

```bash
sudo python3 -c "import json;print(json.load(open('/opt/freqtrade/user_data/config.json'))['api_server']['password'])"
```

Why this shape is the secure one: the UI and the API are **the same origin**, so
`CORS_origins` stays empty and no browser anywhere is trusted; the dashboard is
never exposed to the internet, it is only reachable through an SSH tunnel; it
authenticates with a JWT issued against the `api_server` credentials
(`POST /api/v1/token/login`, access + refresh token); `enable_openapi` is off, so
no schema is published; and the listener is bound to `127.0.0.1` on the host. The
only credential that exists is the one already in `config.json` — adding the
dashboard created no new secret, port or user.

The HamuBot branding is a read-only mount over the image's UI directory:

```
./ui  ->  /freqtrade/freqtrade/rpc/api_server/ui/installed:ro
```

`ui/` is a copy of the shipped FreqUI with the `<title>` and the settings
heading renamed, so the branding survives every container recreate (the image's
copy is untouched and shadowed). Re-create it after an image update with
`sudo bash trading/deploy/brand-ui.sh`, which re-copies and re-patches the files.

That directory is generated, not committed (3 MB of build output the image
already ships, and `.gitignore` excludes it). On a fresh checkout of this repo
the mount therefore points at an empty directory and the dashboard renders
freqtrade's "UI not installed" fallback instead — run `brand-ui.sh` once after
the first `docker compose up`, or drop the mount line to fall back to stock
FreqUI.

## Telegram (phone control + alerts)

Everything about a phone workflow runs through a bot you own. On the VM:

```bash
# once: message @BotFather -> /newbot -> copy the token, then message your new bot "hi"
bash /opt/freqtrade-src/trading/deploy/set-telegram.sh <bot-token>
# or, if you already know your chat id:
bash /opt/freqtrade-src/trading/deploy/set-telegram.sh <bot-token> <chat-id>
```

## What the messages look like

The bot is named `HamuBot` (`bot_name` in `config.json`), which is the bold
header on every notification: startup, warnings, `/status` and the daily summary.
No trading setting is involved — it is a label, and `--strategy` is still
`NASOSv4Wide`.

Every notification is kept on (entries, fills and cancels; exits, fills and
cancels), so you see the full lifecycle. On top of freqtrade's own fill message,
the strategy adds one short recap from its `order_filled` hook, with the numbers
you actually scan for on the last line:

```
🟢 HamuBot · entry filled
NEAR/USDT — 23.4 @ 4.272
stake 99.96 USDT

position open · wallet 1001.74 USDT
```

```
🔵 HamuBot · exit filled
NEAR/USDT — 23.4 @ 4.341
trailing_stop_loss · held 1:36:36

+1.74 USDT · +1.74% · wallet 1001.74 USDT
```

That hook returns nothing and swallows every exception, so a Telegram outage or
a missing field can never affect a trade. It needs
`telegram.allow_custom_messages: true`, which is set.

The daily summary arrives at `01:00` UTC (`notification_settings.daily`), i.e.
21:00 in Montreal.

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

## Phone access with real HTTPS

An SSH tunnel is right for a laptop, clumsy on a phone. The dashboard goes on
your own tailnet instead, with a genuine Let's Encrypt certificate and no
inbound port:

```bash
sudo bash trading/deploy/setup-dashboard-https.sh
```

Run it once from SSH. If the machine is not signed in yet it prints the exact
`tailscale up` command and the approval link; approve the node in a browser, then
re-run the script. It ends with `tailscale serve --bg 8080`, which publishes
`https://<node>.<tailnet>.ts.net/ui` to devices signed in to your tailnet only.

Why Serve and never Funnel: Funnel puts the same port on the public internet,
where freqtrade's single password is the only thing between a stranger and your
exchange account — freqtrade's own docs say not to expose this API publicly. A
Cloudflare *quick* tunnel has the same problem (Cloudflare states any URL holder
can reach the service, and the hostname appears in Certificate Transparency
logs), so it is not used here. With Serve, the free Personal tailnet is the
perimeter: the API stays bound to `127.0.0.1`, `CORS_origins` stays empty, and
`tailscale serve` proxies loopback-to-tailnet with TLS terminated locally.

## What the activity tests showed (2026-11-02)

The complaint was five days without a trade. The bot was not broken: the dry-run
DB contains exactly two orders, both from the first forced trade, so it had
simply never had a setup. Re-running the live config over Oct 30 – Nov 2 with
freshly downloaded candles produced **zero trades as well**, which is the
important agreement — live and backtest say the same thing.

Trades arrive in bursts: 8 in the four days to Oct 30, then nothing. Every lever
that would add trades was measured against the last 30 days (Oct 3 – Nov 2, 14
pairs, fresh data):

| Variant | Trades | Total profit | Max drawdown |
| --- | --- | --- | --- |
| Deployed config (stake 100) | 25 | −0.65% | 3.0% |
| 30-pair universe (top-volume, non-equity) | 25 | −0.14% | 3.0% |
| Stake 200 (2× size) | 25 | −1.29% | 6.0% |
| Stake 300 (3× size) | 25 | −1.94% | 9.0% |
| Upside gate removed (`profit_threshold` 1.0) | 25 | −0.65% | 3.0% |
| Upside gate halved (1.004) | 25 | −0.65% | 3.0% |

Two things fell out of this:

- **Nothing was changed on the live bot.** Every loosening either adds nothing
  (the 0.8% upside gate never binds — identical results) or grows the loss
  (wider universe, bigger stake). Adding trades to a strategy with no edge only
  adds variance.
- **The earlier +0.76% was a window artifact.** The same config measured over a
  30-day window ending Oct 30 was +0.76%; with the last three days included it is
  −0.65%. The win rate is high (84%) but a single −15% stoploss wipes out six
  winners, and position size scales that arithmetic in both directions.

So the honest status is: this is a plausible mechanism without a demonstrated
edge, running for free in dry run. The next step that could actually change the
outcome is a parameter search with an out-of-sample holdout (hyperopt on one
window, validate on another), not a louder version of the same rules.

## Benchmarking other strategies (2026-11-02)

Same 14 pairs, same 90 days (Aug 5 – Nov 2), same stake and slot count, so the
only variable is the strategy. Five stock strategies from
`freqtrade/freqtrade-strategies` were fetched into `user_data/strategies/` and
run unchanged:

| Strategy | Trades | Total profit | Max drawdown | Win rate |
| --- | --- | --- | --- | --- |
| NASOSv4Wide (deployed) | 121 | **+10.28%** | 3.55% | 93.4% |
| Supertrend | 1357 | +9.05% | 8.95% | 46.7% |
| Diamond | 25 | +1.91% | 1.85% | 92.0% |
| Strategy002 | 88 | +0.30% | 1.13% | 51.1% |
| Bandtastic | 2261 | −30.73% | 30.79% | 50.2% |
| MultiMa | — | killed (OOM, exit 137) | — | — |

`MultiMa` is not a result: it was killed by the container's 768 MB cap, which is
the standing limit on this 952 MB host. Two backtests never run concurrently for
the same reason.

The 90-day ranking is misleading on its own, because the same strategy split into
three consecutive windows tells a different story:

| Window | Trades | Total profit |
| --- | --- | --- |
| Aug 5 – Sep 5 | 21 | +0.74% |
| Sep 5 – Oct 5 | 75 | +8.69% |
| Oct 5 – Nov 2 | 25 | −0.62% |

Nearly all of the 90-day profit is September, a dip-and-recover market that suits
a dip-buying strategy. Outside that month the deployed strategy is flat, and the
+10.28% headline is one favourable regime rather than a durable edge.

### The same strategies on the holdout month

The ranking above rewards whoever best exploited September. Re-running the
candidates on Oct 5 – Nov 2, a window none of them was tuned on, inverts it:

| Strategy | Trades | Holdout profit | 90-day profit |
| --- | --- | --- | --- |
| Strategy002 | 34 | +0.17% | +0.30% |
| NASOSv4Wide (deployed) | 25 | −0.62% | +10.28% |
| Diamond | 5 | −1.92% | +1.91% |
| Supertrend | 398 | −7.97% | +9.05% |

`Diamond`'s run was cut short by the memory cap (exit 137) after its summary
printed, so treat its five trades as indicative only.

Nothing survives the holdout as a winner worth switching to. `Supertrend` keeps
almost none of its 90-day profit out of sample and needs 398 trades and a 37%
win rate to lose money, which also costs the most in fees. `Strategy002` is
marginally positive but on 34 trades — indistinguishable from noise. Switching
the bot to any of them would be trading a measured non-edge for an unmeasured
one.

## Parameter search and holdout validation (2026-11-02)

Hyperopt was tried first and abandoned: it was 16 minutes in with no epoch
finished, on a host that was swapping 1 GB of memory, which projects to hours for
30 epochs. A bounded grid over the four gates that decide how often the strategy
fires replaced it. Each variant is a subclass in `NASOSv4Grid.py`, measured on
September 5 – October 5 (the tuning window) and then on October 5 – November 2
(the holdout, never tuned on).

| Variant | Tune: trades / profit | Holdout: trades / profit |
| --- | --- | --- |
| NASOSv4Wide (deployed) | 75 / +8.69% | 25 / −0.62% |
| `low_offset` 0.988 — shallower dip | 104 / **+11.41%** | 46 / **−4.53%** |
| `rsi_buy` 80 — looser RSI ceiling | not completed | not completed |
| `base_nb_candles_buy` 12 | not completed | not completed |
| `lookback_candles` 6 | not completed | not completed |

The single variant that beat the tuning window lost 4.5% on the holdout, with a
5.83% drawdown against the deployed config's −0.62%. That is the overfit the
holdout exists to catch: the shallower dip buys more often, and in September that
was rewarded, but outside it the extra trades were simply worse entries.

**Deploy rule applied: nothing was deployed.** The live bot still runs
`NASOSv4Wide` with `low_offset` 0.984, stake 100, four slots. The remaining three
variants were never measured, because each run costs 5–10 minutes of a swapping
1 GB box, and none of them was expected to outperform the one that already failed
the holdout — a claim to test, not a result.

The general lesson from this whole exercise: on this dataset, every change that
increased trade frequency reduced expectancy on unseen data. No setting found so
far turns the strategy into a reliable earner; it is a mechanism that paid off in
one particular market and gives back outside it.

## Making the bot trade more, and what it cost (2026-11-03)

The bot had taken one entry in four days. Two things were suspected: the hourly
veto in `dont_buy_conditions` (driven by `profit_threshold`) and the depth of the
dip it demands. Both were measured separately on the holdout month.

| Config | Holdout (Oct 5 – Nov 3) | Tune month (Sep 5 – Oct 5) |
| --- | --- | --- |
| NASOSv4Wide, the old deploy | 25 trades, −0.62% | 75 trades, +8.69% |
| Hourly veto removed only | 25 trades, **−0.62%** | not run |
| NASOSv4Active (deployed) | 46 trades, **−4.53%** | 101 trades, +10.86% |

The hourly clause turned out to be irrelevant: removing it produced the *same 25
trades with the same result*, so it never bound. The dip depth was the whole
lever — asking for 1.2% under the 8-EMA instead of 1.6% nearly doubles entries.

The cost of that activity, in the same month: **21 extra trades bought 3.9
percentage points of loss**. Per-trade expectancy falls from −0.025% to −0.098%
while the win rate barely moves (84.0% → 82.6%); the extra trades are not worse
in kind, there are simply more of them losing the same average amount against a
smaller average win. In the September regime the same change is roughly neutral
to slightly better (+10.86% vs +8.69%), which is why it looks harmless until it
meets a month it does not suit.

Deployed anyway, deliberately: this is a dry run, and a bot that never trades
teaches nothing. Reverting is one word in `docker-compose.yml`
(`--strategy NASOSv4Wide`) plus `docker compose up -d`.

### Idle alert

`deploy/idle-alert.sh`, installed at `/usr/local/bin/hamu-idle-alert.sh` and run
from `/etc/cron.d/hamu-idle-alert` every six hours, reads the trade database
read-only and messages Telegram when no new entry has appeared for three days.
It sends at most one alert per 24 hours and clears its state as soon as a trade
opens, so a quiet bot is distinguishable from a broken one.

## Reaching the dashboard from a phone that cannot install anything

`tailscale serve` only works on devices that have joined the tailnet, so a phone
that cannot install the Tailscale app (or change its DNS) sees
`DNS_PROBE_FINISHED_NXDOMAIN` — the name genuinely does not exist on the public
internet, which is the point of it. The answer is `deploy/public-dashboard.sh`:
it keeps the same HTTPS name and certificate but publishes it with Tailscale
Funnel, behind a password gate.

```
sudo sh trading/deploy/public-dashboard.sh   # gate + funnel + credential delivery
sudo tailscale funnel --https=443 off        # back to tailnet-only
```

What the public internet sees is an `nginx:alpine` container listening on
`127.0.0.1:8081` with Basic auth on the UI, proxying to freqtrade on
`127.0.0.1:8080`. Two details matter and both were found the hard way:

- The password file must be `644`. The nginx worker drops privileges, and an
  unreadable file returns **401 to anonymous requests but 500 once credentials
  are supplied**, which looks like a broken proxy rather than a permissions bug.
- `/api/` is deliberately *outside* the gate. A browser carries only one
  `Authorization` header per request, so gating the API too would let the gate
  credentials overwrite FreqUI's own login and the UI would never authenticate.
  The API keeps freqtrade's password check plus an nginx rate limit.

The gate password is generated on the host and delivered over the bot's own
Telegram chat, never through a chat transcript or a committed file.

### Controlling who may reach the dashboard, from Telegram

Since Funnel makes the dashboard reachable from the open internet, an optional
address allowlist can be driven entirely from the owner's Telegram chat — which
matters when the phone cannot install anything and its carrier changes its
address without warning. `deploy/tg-allow.py` runs from
`/etc/cron.d/hamu-tg-admin` every minute and only honours messages from the chat
id in the bot config:

```
/allow 1.2.3.4     let this address in (CIDR also accepted)
/allow             show the current list
/deny 1.2.3.4      remove an address
/allowall          empty the list: password alone is enough again
/help              the commands
```

An empty list means every address may reach the password box. A non-empty one
rewrites `ui-gate/allow.conf` (`allow …; deny all;`), which nginx includes at
server level, then reloads the gate — no restart, no dropped sessions. When the
list is non-empty and a device is refused, the poller reads nginx's access log
and messages the owner the address plus the exact `/allow` line to fix it, so
nobody ever has to look up their own IP; repeats are rate-limited to once an hour
per address.

Two details worth keeping: history before the poller's first run is skipped by
*message date* (an update-id watermark is never seeded when there is no backlog,
which would otherwise swallow the owner's first real command), and a bare
address must canonicalise identically to its `/32` form, or `/allow` twice adds a
duplicate that `/deny` cannot remove.

The lockout story is deliberate: the allowlist can refuse the phone, but the
Telegram chat is server-side, so `/allowall` always gets the owner back in. From
SSH it is `: > /opt/freqtrade/ui-gate/allowlist.txt` plus
`python3 /usr/local/bin/hamu-tg-admin.py --rebuild`.

### Making it trade more, with numbers instead of guesses

The bot had taken exactly **one** trade in its life, and that one was a manual
`force_entry`. Diagnosing it turned up two separate causes, neither of which was
"the strategy is broken":

* the strategy had only been running as `NASOSv4Active` since 00:06 that day —
  every earlier restart resolved to `NASOSv4Wide` or `SampleStrategy`, so
  "weeks with no trade" was mostly "the strategy kept being switched";
* both entry gates were binding at once. The bot's own analysed dataframe showed
  every pair at `EWO` between −0.3 and −2.6 while the entry needs `EWO > 0`, and
  the closest dip in the last 100 candles was INJ at 0.98927 against a 0.988
  threshold, i.e. it missed by 0.1%.

Variants in `strategies/HamuFaster.py` and `HamuFaster2.py` change one lever
each. `HF_base` reproduces the deployed entry (270 trades vs 268) so the
comparisons are attributable, and every run used the same 20 pairs over
2026-09-01 .. 2026-11-03.

| Entry | Exit | Trades | Profit | Drawdown | Avg held |
|---|---|---|---|---|---|
| NASOSv4Active (deployed then) | +1.6% trailing | 268 | +20.0% | 7.05% | 22h |
| dip 0.992 (looser dip) | +1.6% trailing | 371 | **+5.7%** | 18.05% | 1d 2h |
| dip 0.995 | +1.6% trailing | 386 | +14.3% | 17.35% | 1d 5h |
| NASOSv4Active | **+1.0% take, 0.2% trail** | 326 | +17.1% | **3.68%** | 12h |
| **HF2_ewoM2 (`EWO > −2`)** | **+1.0% take, 0.2% trail** | **412** | **+18.1%** | 6.24% | 15h |

Loosening the entry dip is a trap: 38% more trades for a quarter of the profit
and two and a half times the drawdown. The two levers that pay are a faster exit
(half the drawdown, half the holding time, +21% trades) and letting the regime
gate fall to −2 (another +26% trades at the same total profit). That combination
is what `docker-compose.yml` and `config.json` now run: 20 pairs, 8 slots, take
profit at +1.0%, 0.2% trail, `--strategy HF2_ewoM2`.

Exits are configured in `config.json`, not in the strategy class — the config
overrides `minimal_roi` and `trailing_*`, which is why an exit-only subclass came
out bit-identical to its control.

**Out of sample, this is not a money machine.** On the seven pairs with longer
history, the same setup over 2026-03-04 .. 2026-09-01 made +0.98% in six months
at 0.85 trades/day (profit factor 1.07). The recent 62 days were a good regime.
Expect long flat stretches, and treat the activity level — not the return — as
the thing that changed.

Revert everything with `--strategy NASOSv4Active` in the compose file, plus
`minimal_roi {"0": 10.0}`, `trailing_stop_positive_offset 0.016` and
`trailing_stop_positive 0.001` in `config.json`.

#### Correction: the allowlist does not read Telegram by default

`tg-allow.py` originally polled `getUpdates` once a minute from cron, which is
wrong on a host where freqtrade is running: a bot token may only be long-polled
by one process, so the two evicted each other with `HTTP 409 Conflict` — the
bot's own commands were dropped and the poller never received a message. The
freqtrade log recorded the damage as
`telegram.error.Conflict: terminated by other getUpdates request`.

The cron entry therefore runs the script with no arguments, which only *sends*
(refusal reports) and rebuilds `allow.conf`; reading commands requires `--poll`
and a bot of its own, or freqtrade's Telegram disabled. With an empty allowlist
the reports are a no-op, so in practice the password gate is the control and the
list is managed from the host. Wiring `/allow` back up means creating a second
bot in BotFather and putting its token on the VM — it must not be pasted into a
chat, since a token in a chat log is a token someone else can use.

### Round four: auditing the risk side, and a published strategy on the same bench

Rounds one to three only ever changed the entry. The audit of `config.json` found
the asymmetry nobody had looked at: the bot takes profit at **+1.0%** and carries a
hard stop at **−15%**. At a 95% win rate that reads "the stop never fires", but one
trigger erases fifteen winners, so it was tested rather than argued about.

63 days, 20 pairs, deployed exit, one change per run:

| Variant | Trades | Profit | Drawdown |
|---|---|---|---|
| **Deployed (control)** | 413 | **+17.96%** | 6.33% |
| dip 0.990 (1.0% under the EMA) | 472 | +8.07% | 13.93% |
| dip 0.992 (0.8% under the EMA) | 561 | +8.67% | 17.21% |
| `rsi_fast` ceiling 45 | 413 | +17.96% | 6.33% (bit-identical) |
| ASGO `momentum_5m` (published 5m breakout) | 320 | +4.22% | 15.40% |
| stoploss −8% | 488 | +4.11% | — |
| stoploss −5% | 565 | −2.56% | — |
| stoploss −3% | 631 | −0.72% | — |

Profit falls monotonically as the stop tightens, so the wide stop is not a bug to
fix: this is a mean-reversion entry, it is supposed to survive being early, and a
tight stop simply converts the 95% of winners that dip further into 3% losses. The
`rsi_fast` ceiling is not binding at all (45 produced exactly the control's
trades), and both depth variants buy more but pay three to five times the drawdown.

The external candidate is `ASGOMom.py`, a faithful port of traxguo/ASGO.ai's
`momentum_5m` (range expansion, 20-bar breakout, green candle, −1.5%/+3%). It is
the best-documented 5m rule set found online, with the author's own fee study
admitting it goes negative at retail fees — and on our data it made +4.2% against
the deployed +18.0%, with more drawdown, so it stays on the bench, not in the
compose file. NostalgiaForInfinity was **not** run: it is a 2.8 MB file needing 800
startup candles, five timeframes and 40-80 pairs, which does not fit a 768 MB
container on a 1 GB VM, and its results are only published in commit comments.

Operational findings from the audit, all fixed or recorded:

* seven pairs had candles ending 2026-10-30, 92 hours stale, because the download
  had only ever covered a subset — `download-data --days 75` refreshed all twenty
  to the present;
* `process_only_new_candles` was unset, so indicators were recomputed on every
  five-second loop; now `true`;
* there are no protections/cooldowns, and entries are limit orders with a 10-minute
  unfilled timeout — backtests assume a fill at candle close, so live fills will be
  somewhat worse than the table above. That gap is recorded here rather than
  papered over with an unmeasured change.

## Files

| Path | What it is |
|---|---|
| `user_data/strategies/NASOSv4.py` | upstream strategy: entry logic, EWO, RSI, sell trend |
| `user_data/strategies/NASOSv4Wide.py` | parent with the shallower 1.6% dip and the notification hook |
| `user_data/strategies/NASOSv4Active.py` | 1.2% dip, hourly-high veto dropped |
| `user_data/strategies/HamuFaster.py` | round one: dip depth and exit-speed variants |
| `user_data/strategies/HamuFaster2.py` | round two: regime-gate variants (**HF2_ewoM2 is live**) |
| `user_data/strategies/HamuBest.py` | round four: entry-depth and RSI variants |
| `user_data/strategies/ASGOMom.py` | ported external 5m breakout candidate |
| `user_data/backtest_all.json` | 20 pairs, 8 slots overlay |
| `user_data/backtest_fast_exit.json` | deployed exit overlay |
| `user_data/backtest_sl*.json` | stop-loss overlays for round four |
