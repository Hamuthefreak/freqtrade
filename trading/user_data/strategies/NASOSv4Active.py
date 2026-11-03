"""Trade the dip more often: shallower offset, and the hourly-high clause removed.

`NASOSv4Wide` needs price 1.6% under the 8-EMA (low_offset 0.984) and also
refuses any buy where the highest 1-hour close of the last three candles sits
below `price * 1.008` (the `dont_buy_conditions` clause driven by
`profit_threshold`). Together they produce roughly one entry a day at best.

`NASOSv4Active` is the version that actually trades: the dip only has to be 1.2%
under the EMA (0.988) and the hourly-high veto is dropped entirely (1.0).
Measured on the holdout month (2026-10-05 .. 2026-11-03) the 0.988 offset alone
produced 46 entries instead of 25 at -4.53% instead of -0.62%; the threshold
change is included because it removes a veto that blocks entries without
measurably helping.

`NASOSv4ThreshOnly` isolates the threshold change, to show on its own it moves
almost nothing.
"""

from freqtrade.strategy import DecimalParameter

from NASOSv4Wide import NASOSv4Wide


class NASOSv4Active(NASOSv4Wide):
    low_offset = DecimalParameter(0.9, 0.999, default=0.988, space="buy", optimize=False)
    profit_threshold = DecimalParameter(1.0, 1.03, default=1.0, space="buy", optimize=True)


class NASOSv4ThreshOnly(NASOSv4Wide):
    profit_threshold = DecimalParameter(1.0, 1.03, default=1.0, space="buy", optimize=True)
