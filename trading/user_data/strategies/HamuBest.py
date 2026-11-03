"""Round four: the risk side, which round one to three never touched.

The audit found something worse than a missing entry: the deployed config takes
profit at +1.0% but carries a hard stop at -15%. Backtested win rates here are
94-96%, so one full stop wipes out fifteen winners. Whether that is "safe because
it never triggers" or "one bad candle undoes a month" is an empirical question,
so the stop is tested at -3%, -5% and -8% alongside the entry variants.

Note on how the stop has to be tested: `config.json` sets `stoploss`, and config
beats strategy attributes, so a class-level stoploss is ignored live and in
backtests. The stops are therefore driven by overlay files
(backtest_sl03.json, backtest_sl05.json, backtest_sl08.json), exactly the way the
exit speed had to be.

These subclasses cover the entry-side levers, all still on top of the deployed
`HF2_ewoM2` (dip 1.2% under the 8-EMA, regime gate EWO > -2):

  HB_ctrl     control; must reproduce the deployed 412-trade run
  HB_dip990   dip 1.0% under the EMA
  HB_dip992   dip 0.8% under the EMA
  HB_rsi45    rsi_fast ceiling 45 instead of 35 (more entries at shallower RSI dips)

Run with backtest_fast_exit.json so everything is compared at the deployed exit.
"""

from freqtrade.strategy import DecimalParameter, IntParameter

from HamuFaster2 import HF2_ewoM2


class HB_ctrl(HF2_ewoM2):
    """Control: the deployed entry, unchanged, to prove the copy has not drifted."""


class HB_dip990(HF2_ewoM2):
    low_offset = DecimalParameter(0.9, 0.999, default=0.990, space="buy", optimize=False)


class HB_dip992(HF2_ewoM2):
    low_offset = DecimalParameter(0.9, 0.999, default=0.992, space="buy", optimize=False)


class HB_rsi45(HF2_ewoM2):
    rsi_fast_max = IntParameter(20, 60, default=45, space="buy", optimize=False)
