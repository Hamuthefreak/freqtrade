"""Round two: the market-regime gate and the exit speed.

Round one (HamuFaster.py) showed the dip depth is not a free lever: buying 0.8%
under the EMA raised trades 38% and cut profit from 20.0% to 5.7% over the same
62 days, with 18% drawdown instead of 7%. So the entry dip stays at 0.988.

That leaves the two levers that were actually blocking activity:

  EWO > 0   the entry refuses to buy unless the 5m EMA50 sits above the EMA200.
            In the first week of November every pair was below it, so nothing
            could fire no matter how deep the dip. HF2_ewoM1 / HF2_ewoM2 let the
            gate fall below zero by one or two percent of price.
  exits     the live config overrides the strategy's trailing and ROI, which is
            why HF_quick came out bit-identical to the control in round one.
            Exit speed is therefore tested with a config overlay
            (backtest_fast_exit.json), not with a subclass.

Run both overlays over the same window so the exit comparison is like-for-like.
"""

from freqtrade.strategy import DecimalParameter

from HamuFaster import HF_base


class HF2_ewo0(HF_base):
    """Control: unchanged regime gate, kept identical to HF_base on purpose."""


class HF2_ewoM1(HF_base):
    """Allow entries when the 5m trend is only mildly negative."""

    ewo_high = DecimalParameter(-12.0, 12.0, default=-1.0, space="buy", optimize=False)


class HF2_ewoM2(HF_base):
    """Allow entries in a clearly falling 5m trend."""

    ewo_high = DecimalParameter(-12.0, 12.0, default=-2.0, space="buy", optimize=False)
