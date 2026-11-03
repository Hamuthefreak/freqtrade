"""A published 5m breakout strategy, ported so it can be put on the same bench.

Source: traxguo/ASGO.ai, strategies/candidates/momentum_5m.py, with the rules
from cards/momentum_5m.md. Their own study is unusually honest: over 2022-2024 on
16 coins with costs it made +17.6% total at PF 1.01, and at 0.2%/side it lost
99.8%. That is exactly why it belongs here: if a strategy with published,
fee-aware results cannot beat the dip strategy on our own data, it is not an
improvement, and if it can, we learned something.

Long entry, all evaluated on the 5m candle:
  * SMA(10) of the candle range above SMA(50) of the range  (volatility expanding)
  * close above the close 20 bars ago                        (short-term up)
  * close above the highest close of the previous 20 bars     (fresh breakout)
  * green candle
Exit: -1.5% hard stop, +3% target, no trailing.

Kept deliberately identical to the published rule set rather than tuned, so the
comparison is against their strategy and not against another hyperopt of ours.
"""

from pandas import DataFrame
import talib.abstract as ta

from freqtrade.strategy import IStrategy


class ASGO_momentum_5m(IStrategy):
    INTERFACE_VERSION = 2

    timeframe = '5m'
    startup_candle_count = 60
    process_only_new_candles = True

    minimal_roi = {"0": 0.03}
    stoploss = -0.015
    trailing_stop = False
    use_sell_signal = True
    sell_profit_only = False
    ignore_roi_if_buy_signal = False

    def populate_indicators(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        candle_range = dataframe['high'] - dataframe['low']
        dataframe['range_sma10'] = candle_range.rolling(10).mean()
        dataframe['range_sma50'] = candle_range.rolling(50).mean()
        dataframe['close_20_back'] = dataframe['close'].shift(20)
        # highest close of the *previous* 20 bars, so the current bar must exceed it
        dataframe['close_20_high'] = dataframe['close'].rolling(20).max().shift(1)
        return dataframe

    def populate_buy_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe.loc[
            (
                (dataframe['range_sma10'] > dataframe['range_sma50'])
                & (dataframe['close'] > dataframe['close_20_back'])
                & (dataframe['close'] > dataframe['close_20_high'])
                & (dataframe['close'] > dataframe['open'])
                & (dataframe['volume'] > 0)
            ),
            ['buy', 'buy_tag']] = (1, 'asgo_mom')
        return dataframe

    def populate_sell_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        dataframe.loc[:, 'sell'] = 0
        return dataframe
