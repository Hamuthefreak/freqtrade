"""Keep NASOSv4's deep-dip entry, drop only the EWO trend gate.

The shipped strategy needs a 1.6% dip below the 8-EMA *and* EWO > 2.4. The dip
is the actual edge (that version is the only candidate that made money on our
data); the trend gate is what made it fire zero times in a week. These two
variants keep the dip depth and let the trend condition go, so the bot trades
roughly once a day instead of once a fortnight.

Wide  = original exit logic (wide stoploss, 1.6% trailing activation).
Tight = same entry, small stoploss and quicker take-profit.

The only addition to the parent class is `order_filled`, which posts a compact
Telegram recap after each fill. It reads trade state and sends a message; it
never returns a value, never changes a price and swallows every error, so it
cannot alter trading behaviour even if Telegram is down or a field is missing.
"""

import logging

from freqtrade.strategy import DecimalParameter

from NASOSv4 import NASOSv4

logger = logging.getLogger(__name__)


class NASOSv4Wide(NASOSv4):
    low_offset = DecimalParameter(0.9, 0.999, default=0.984, space="buy", optimize=False)
    low_offset_2 = DecimalParameter(0.9, 0.999, default=0.97, space="buy", optimize=False)
    ewo_high = DecimalParameter(-12.0, 12.0, default=0.0, space="buy", optimize=False)
    ewo_high_2 = DecimalParameter(-12.0, 12.0, default=-3.0, space="buy", optimize=False)

    # ---- HamuBot notifications (cosmetic only) -------------------------------

    def order_filled(self, pair, trade, order, current_time, **kwargs):
        """Send one recap per fill, with the headline as the last bold line.

        freqtrade already sends its own fill message; this adds the short
        "what you actually care about" summary underneath it.
        """
        try:
            if order.status != "closed" or not order.filled:
                return

            rate = order.average or trade.open_rate
            amount = order.filled

            if getattr(order, "ft_order_side", "buy") == "buy":
                body = (
                    f"🟢 *HamuBot* · entry filled\n"
                    f"{pair} — {amount:g} @ {rate:g}\n"
                    f"stake {trade.stake_amount:.2f} USDT\n"
                    f"\n*position open · {self._hamubot_wallet()}*"
                )
            else:
                try:
                    pnl = trade.calc_profit(rate=rate)
                    pct = trade.calc_profit_ratio(rate=rate) * 100
                    money = f"{pnl:+.2f} USDT · {pct:+.2f}%"
                except Exception:
                    money = "P&L unavailable"

                held = ""
                try:
                    delta = current_time - trade.open_date_utc
                    held = f" · held {str(delta).split('.')[0]}"
                except Exception:
                    pass

                reason = trade.exit_reason or "exit"
                body = (
                    f"🔵 *HamuBot* · exit filled\n"
                    f"{pair} — {amount:g} @ {rate:g}\n"
                    f"{reason}{held}\n"
                    f"\n*{money} · {self._hamubot_wallet()}*"
                )

            self.dp.send_msg(body, always_send=True)
        except Exception as exc:  # never let a message break a trade
            logger.debug("HamuBot recap skipped for %s: %s", pair, exc)

    def _hamubot_wallet(self) -> str:
        try:
            return f"wallet {self.wallets.get_total_stake_amount():.2f} USDT"
        except Exception:
            return "wallet n/a"


class NASOSv4WideTight(NASOSv4Wide):
    stoploss = -0.05
    minimal_roi = {"0": 0.015, "30": 0.008}
    trailing_stop = True
    trailing_stop_positive = 0.005
    trailing_stop_positive_offset = 0.012
    trailing_only_offset_is_reached = True
