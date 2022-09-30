//+------------------------------------------------------------------+
//|                                                              HAN |
//|                             Copyright © 2013-2022, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2013-2022, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/Heiken-Ashi-Naive/"
#property version   "1.03"
#property strict

#property description "Uses Heiken Ashi candles."
#property description "Buy: Bullish HA candle, no lower wick, body longer than prev. body, prev. candle bullish."
#property description "Sell: Bearish HA candle, no upper wick, body longer than prev. body, prev. candle bearish."
#property description "Exit buy: Bearish HA candle, current candle has no upper wick, previous also bearish."
#property description "Exit sell: Bullish HA candle, current candle has no lower wick, previous also bullish."
#property description "You can choose either direct trading (buy on bullish) or inverted (sell on bullish)."

// Main:
input bool Inverted = true; // Inversion: If true, sells on Bullish signals, buys on Bearish.

// Money management:
input double Lots = 0.1; // Lots: Basic lot size
input bool MM  = false; // MM: If true - ATR-based position sizing
input int ATR_Period = 20;
input double ATR_Multiplier = 1;
input double Risk = 2; // Risk: Risk tolerance in percentage points
input double FixedBalance = 0; // FixedBalance: If >= 0, will use it instead of actual balance.
input double MoneyRisk = 0; // MoneyRisk: Risk tolerance in base currency
input bool UseMoneyInsteadOfPercentage = false;
input bool UseEquityInsteadOfBalance = false;

// Miscellaneous:
input string OrderCommentary = "HAN";
input int Slippage = 100;  // Slippage: Tolerated slippage in points
input int Magic = 1520122013;  // Magic: Order magic number

// Global variables:
int LastBars = 0;
bool HaveLongPosition;
bool HaveShortPosition;
double StopLoss; // Not the actual stop-loss - just a potential loss of MM estimation.

void OnTick()
{
    if ((!IsTradeAllowed()) || (IsTradeContextBusy()) || (!IsConnected()) || ((!MarketInfo(Symbol(), MODE_TRADEALLOWED)) && (!IsTesting()))) return;

    // Trade only if a new bar has arrived.
    if (LastBars != Bars) LastBars = Bars;
    else return;

    if (MM)
    {
        // Getting the potential loss value based on current ATR.
        StopLoss = iATR(NULL, 0, ATR_Period, 1) * ATR_Multiplier;
    }

    // Close conditions.
    bool BearishClose = false;
    bool BullishClose = false;

    // Signals.
    bool Bullish = false;
    bool Bearish = false;

    // Heiken Ashi indicator values.
    double HAOpenLatest, HAOpenPrevious, HACloseLatest, HAClosePrevious, HAHighLatest, HALowLatest;

    HAOpenLatest = iCustom(NULL, 0, "Heiken Ashi", 2, 1);
    HAOpenPrevious = iCustom(NULL, 0, "Heiken Ashi", 2, 2);
    HACloseLatest = iCustom(NULL, 0, "Heiken Ashi", 3, 1);
    HAClosePrevious = iCustom(NULL, 0, "Heiken Ashi", 3, 2);
    if (HAOpenLatest >= HACloseLatest) HAHighLatest = iCustom(NULL, 0, "Heiken Ashi", 0, 1);
    else HAHighLatest = iCustom(NULL, 0, "Heiken Ashi", 1, 1);
    if (HAOpenLatest >= HACloseLatest) HALowLatest = iCustom(NULL, 0, "Heiken Ashi", 1, 1);
    else HALowLatest = iCustom(NULL, 0, "Heiken Ashi", 0, 1);

    // Close signals.
    // Bullish HA candle, current has no lower wick, previous also bullish.
    if ((HAOpenLatest < HACloseLatest) && (HALowLatest == HAOpenLatest) && (HAOpenPrevious < HAClosePrevious))
    {
        if (Inverted) BullishClose = true;
        else BearishClose = true;
    }
    // Bearish HA candle, current has no upper wick, previous also bearish.
    else if ((HAOpenLatest > HACloseLatest) && (HAHighLatest == HAOpenLatest) && (HAOpenPrevious > HAClosePrevious))
    {
        if (Inverted) BearishClose = true;
        else BullishClose = true;
    }

    // First entry condition
    // Bullish HA candle, and body is longer than previous body, previous also bullish, current has no lower wick.
    if ((HAOpenLatest < HACloseLatest) && (HACloseLatest - HAOpenLatest > MathAbs(HAClosePrevious - HAOpenPrevious)) && (HAOpenPrevious < HAClosePrevious) && (HALowLatest == HAOpenLatest))
    {
        if (Inverted)
        {
            Bullish = false;
            Bearish = true;
        }
        else
        {
            Bullish = true;
            Bearish = false;
        }
    }
    // Second entry condition
    // Bearish HA candle, and body is longer than previous body, previous also bearish, current has no upper wick.
    else if ((HAOpenLatest > HACloseLatest) && (HAOpenLatest - HACloseLatest > MathAbs(HAClosePrevious - HAOpenPrevious)) && (HAOpenPrevious > HAClosePrevious) && (HAHighLatest == HAOpenLatest))
    {
        if (Inverted)
        {
            Bullish = true;
            Bearish = false;
        }
        else
        {
            Bullish = false;
            Bearish = true;
        }
    }
    else
    {
        Bullish = false;
        Bearish = false;
    }

    GetPositionStates();

    if ((HaveShortPosition) && (BearishClose)) ClosePrevious();
    if ((HaveLongPosition) && (BullishClose)) ClosePrevious();

    if (Bullish)
    {
        if (!HaveLongPosition) fBuy();
    }
    else if (Bearish)
    {
        if (!HaveShortPosition) fSell();
    }
}

//+------------------------------------------------------------------+
//| Check what position is currently open.                           |
//+------------------------------------------------------------------+
void GetPositionStates()
{
    int total = OrdersTotal();
    for (int cnt = 0; cnt < total; cnt++)
    {
        if (OrderSelect(cnt, SELECT_BY_POS, MODE_TRADES) == false) continue;
        if (OrderMagicNumber() != Magic) continue;
        if (OrderSymbol() != Symbol()) continue;

        if (OrderType() == OP_BUY)
        {
            HaveLongPosition = true;
            HaveShortPosition = false;
            return;
        }
        else if (OrderType() == OP_SELL)
        {
            HaveLongPosition = false;
            HaveShortPosition = true;
            return;
        }
    }
    HaveLongPosition = false;
    HaveShortPosition = false;
}

//+------------------------------------------------------------------+
//| Buy                                                              |
//+------------------------------------------------------------------+
void fBuy()
{
    RefreshRates();
    int result = OrderSend(Symbol(), OP_BUY, LotsOptimized(), Ask, Slippage, 0, 0, OrderCommentary, Magic);
    if (result == -1)
    {
        int e = GetLastError();
        Print("OrderSend Error: ", e);
    }
}

//+------------------------------------------------------------------+
//| Sell                                                             |
//+------------------------------------------------------------------+
void fSell()
{
    RefreshRates();
    int result = OrderSend(Symbol(), OP_SELL, LotsOptimized(), Bid, Slippage, 0, 0, OrderCommentary, Magic);
    if (result == -1)
    {
        int e = GetLastError();
        Print("OrderSend Error: ", e);
    }
}

//+------------------------------------------------------------------+
//| Calculate position size depending on money management parameters.|
//+------------------------------------------------------------------+
double LotsOptimized()
{
    if (!MM) return (Lots);

    double Size, RiskMoney, PositionSize = 0;

    if (AccountCurrency() == "") return(0);

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountEquity();
    }
    else
    {
        Size = AccountBalance();
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    double UnitCost = MarketInfo(Symbol(), MODE_TICKVALUE);
    double TickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
    int LotStep_digits = CountDecimalPlaces(MarketInfo(Symbol(), MODE_LOTSTEP));

    if ((StopLoss != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (StopLoss * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < MarketInfo(Symbol(), MODE_MINLOT)) PositionSize = MarketInfo(Symbol(), MODE_MINLOT);
    else if (PositionSize > MarketInfo(Symbol(), MODE_MAXLOT)) PositionSize = MarketInfo(Symbol(), MODE_MAXLOT);

    return PositionSize;
}

//+------------------------------------------------------------------+
//| Close previous position.                                         |
//+------------------------------------------------------------------+
void ClosePrevious()
{
    int total = OrdersTotal();
    for (int i = 0; i < total; i++)
    {
        if (OrderSelect(i, SELECT_BY_POS) == false) continue;
        if ((OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic))
        {
            if (OrderType() == OP_BUY)
            {
                RefreshRates();
                if (!OrderClose(OrderTicket(), OrderLots(), Bid, Slippage))
                {
                    int e = GetLastError();
                    Print("OrderClose Error: ", e);
                }
            }
            else if (OrderType() == OP_SELL)
            {
                RefreshRates();
                if (!OrderClose(OrderTicket(), OrderLots(), Ask, Slippage))
                {
                    int e = GetLastError();
                    Print("OrderClose Error: ", e);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Counts decimal places.                                           |
//+------------------------------------------------------------------+
int CountDecimalPlaces(double number)
{
    // 100 as maximum length of number.
    for (int i = 0; i < 100; i++)
    {
        double pwr = MathPow(10, i);
        if (MathRound(number * pwr) / pwr == number) return i;
    }
    return -1;
}
//+------------------------------------------------------------------+