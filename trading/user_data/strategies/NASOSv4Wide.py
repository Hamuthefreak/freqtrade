"""Keep NASOSv4's deep-dip entry, drop only the EWO trend gate.

The shipped strategy needs a 1.6% dip below the 8-EMA *and* EWO > 2.4. The dip
is the actual edge (that version is the only candidate that made money on our
data); the trend gate is what made it fire zero times in a week. These two
variants keep the dip depth and let the trend condition go, so the bot trades
roughly once a day instead of once a fortnight.

Wide  = original exit logic (wide stoploss, 1.6% trailing activation).
Tight = same entry, small stoploss and quicker take-profit.
"""

from freqtrade.strategy import DecimalParameter

from NASOSv4 import NASOSv4


class NASOSv4Wide(NASOSv4):
    low_offset = DecimalParameter(0.9, 0.999, default=0.984, space="buy", optimize=False)
    low_offset_2 = DecimalParameter(0.9, 0.999, default=0.97, space="buy", optimize=False)
    ewo_high = DecimalParameter(-12.0, 12.0, default=0.0, space="buy", optimize=False)
    ewo_high_2 = DecimalParameter(-12.0, 12.0, default=-3.0, space="buy", optimize=False)


class NASOSv4WideTight(NASOSv4Wide):
    stoploss = -0.05
    minimal_roi = {"0": 0.015, "30": 0.008}
    trailing_stop = True
    trailing_stop_positive = 0.005
    trailing_stop_positive_offset = 0.012
    trailing_only_offset_is_reached = True
