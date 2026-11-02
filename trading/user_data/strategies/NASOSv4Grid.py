"""A bounded grid over the levers that decide how often NASOSv4Wide fires.

Full hyperopt proved unaffordable on this 1 GB box (no epoch finished in 16
minutes, so 30 epochs projected to hours). These four variants each loosen one
gate, which is enough to answer the question the search was meant to answer:
does relaxing anything raise trades without losing money out of sample.

Tune on 2026-09-05 .. 2026-10-05, validate on 2026-10-05 .. 2026-11-03.
"""

from freqtrade.strategy import DecimalParameter, IntParameter

from NASOSv4Wide import NASOSv4Wide


class G_low0988(NASOSv4Wide):
    """Shallower dip: buy 1.2% under the EMA8 instead of 1.6%."""
    low_offset = DecimalParameter(0.9, 0.99, default=0.988, space="buy", optimize=False)


class G_rsi80(NASOSv4Wide):
    """Loose RSI ceiling."""
    rsi_buy = IntParameter(50, 100, default=80, space="buy", optimize=False)


class G_base12(NASOSv4Wide):
    """Slower entry EMA, so the dip is measured against a calmer baseline."""
    base_nb_candles_buy = IntParameter(2, 20, default=12, space="buy", optimize=True)


class G_look6(NASOSv4Wide):
    """Wider window for the upside requirement."""
    lookback_candles = IntParameter(1, 24, default=6, space="buy", optimize=True)
