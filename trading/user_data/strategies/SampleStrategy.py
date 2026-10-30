"""Minimal starter strategy for the dry-run bot.

Why this file exists: the freqtrade image ships no strategy of its own, and the
sample strategy shown in the docs is not importable from inside the container.
Without a strategy in user_data/strategies the bot refuses to start with
"Impossible to load Strategy 'SampleStrategy'".

The logic is deliberately plain (RSI pullback in an uptrend, exit when
overbought) - it exists so the plumbing runs end to end in dry run, not because
it makes money. Replace it, or point --strategy at your own file, once you have
a real edge to test.
"""

from pandas import DataFrame

import talib.abstract as ta

from freqtrade.strategy import IStrategy


class SampleStrategy(IStrategy):
    INTERFACE_VERSION = 3

    # Keep these in sync with user_data/config.json; config values win at runtime.
    minimal_roi = {"0": 0.04, "30": 0.02, "60": 0.01}
    stoploss = -0.10
    timeframe = "5m"

    # Long enough for the slow EMA to be meaningful on the first analysed candle.
    startup_candle_count = 30

    process_only_new_candles = True
    use_exit_signal = True
    exit_profit_only = False
    ignore_roi_if_entry_signal = False

    def populate_indicators(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe["rsi"] = ta.RSI(dataframe, timeperiod=14)
        dataframe["ema_fast"] = ta.EMA(dataframe, timeperiod=12)
        dataframe["ema_slow"] = ta.EMA(dataframe, timeperiod=26)
        return dataframe

    def populate_entry_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe.loc[
            (
                (dataframe["rsi"] < 35)
                & (dataframe["ema_fast"] > dataframe["ema_slow"])
                & (dataframe["volume"] > 0)
            ),
            ["enter_long", "enter_tag"],
        ] = (1, "rsi_pullback")
        return dataframe

    def populate_exit_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe.loc[
            (
                (dataframe["rsi"] > 65)
                & (dataframe["volume"] > 0)
            ),
            ["exit_long", "exit_tag"],
        ] = (1, "rsi_overbought")
        return dataframe
