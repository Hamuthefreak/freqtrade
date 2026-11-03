"""Variants that trade more often, and recycle capital faster.

The deployed `NASOSv4Active` is not broken, it is rare: it needs a dip under the
8-EMA *while* the 5m EWO is positive, and then holds the position until it is
1.6% up before trailing it 0.1% behind. On the last week of data that worked out
to 9 entries held for ~1.5 days each, so most of the time there is nothing to
look at even though the bot is healthy.

These subclasses change one lever each, so the comparison stays attributable:

  HF_base            control: identical logic, rsi_fast made a parameter
  HF_dip08           dip 0.8% under the EMA instead of 1.2%
  HF_dip10           dip 0.5% under the EMA
  HF_quick           same entry, exit at +1.0% trailing 0.2% (capital comes back)
  HF_dip08_quick     both of the above
  HF_rsi50           rsi_fast ceiling 50 instead of 35, dip 0.8%

`HF_base` matters: it must reproduce the parent's trades, otherwise the copied
entry code below has drifted and every other number here is untrustworthy.

Tune on 2026-09-01 .. 2026-11-03 over all 20 pairs, validate the winner on
2026-03-04 .. 2026-09-01 over the seven pairs that have that history.
"""

from freqtrade.strategy import DecimalParameter, IntParameter

from NASOSv4Active import NASOSv4Active


class HF_base(NASOSv4Active):
    """Parent's entry, with the rsi_fast ceiling exposed as a parameter."""

    rsi_fast_max = IntParameter(20, 60, default=35, space="buy", optimize=False)

    def populate_buy_trend(self, dataframe, metadata):
        ma_buy = dataframe[f"ma_buy_{self.base_nb_candles_buy.value}"]
        ma_sell = dataframe[f"ma_sell_{self.base_nb_candles_sell.value}"]
        common = (
            (dataframe["rsi_fast"] < self.rsi_fast_max.value)
            & (dataframe["volume"] > 0)
            & (dataframe["close"] < ma_sell * self.high_offset.value)
        )
        volume_and_rsi = (dataframe["rsi"] < self.rsi_buy.value) & (dataframe["volume"] > 0)

        dataframe.loc[
            common
            & (dataframe["close"] < ma_buy * self.low_offset.value)
            & (dataframe["EWO"] > self.ewo_high.value)
            & volume_and_rsi,
            ["buy", "buy_tag"],
        ] = (1, "ewo1")

        dataframe.loc[
            common
            & (dataframe["close"] < ma_buy * self.low_offset_2.value)
            & (dataframe["EWO"] > self.ewo_high_2.value)
            & volume_and_rsi
            & (dataframe["rsi"] < 25),
            ["buy", "buy_tag"],
        ] = (1, "ewo2")

        dataframe.loc[
            common
            & (dataframe["close"] < ma_buy * self.low_offset.value)
            & (dataframe["EWO"] < self.ewo_low.value),
            ["buy", "buy_tag"],
        ] = (1, "ewolow")

        # Parent's "don't buy into a new high" veto, unchanged.
        if self.profit_threshold.value > 1.0:
            veto = (
                dataframe["close_1h"].rolling(self.lookback_candles.value).max()
                < (dataframe["close"] * self.profit_threshold.value)
            )
            dataframe.loc[veto, "buy"] = 0

        return dataframe


class HF_dip08(HF_base):
    """Buy 0.8% under the 8-EMA instead of 1.2%."""

    low_offset = DecimalParameter(0.9, 0.999, default=0.992, space="buy", optimize=False)


class HF_dip10(HF_base):
    """Buy 0.5% under the 8-EMA."""

    low_offset = DecimalParameter(0.9, 0.999, default=0.995, space="buy", optimize=False)


class HF_quick(HF_base):
    """Same entries, but take the money at +1.0% and trail 0.2% behind it."""

    trailing_stop_positive = 0.002
    trailing_stop_positive_offset = 0.010
    minimal_roi = {"0": 0.02}


class HF_dip08_quick(HF_dip08):
    trailing_stop_positive = 0.002
    trailing_stop_positive_offset = 0.010
    minimal_roi = {"0": 0.02}


class HF_rsi50(HF_dip08):
    """Also accept a shallower RSI dip (rsi_fast < 50)."""

    rsi_fast_max = IntParameter(20, 60, default=50, space="buy", optimize=False)
