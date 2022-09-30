//+------------------------------------------------------------------+
//|                                                      HAN_Z-Score |
//|                             Copyright © 2013-2022, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2013-2022, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/Heiken-Ashi-Naive/"
#property version   "1.03"
#property strict

#include <stdlib.mqh>

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
input bool Mute = false; // No output about virtual trading
input string FileName = "HAN_vt.dat";

// Global variables:
// Common:
int LastBars = 0;
bool HaveLongPosition;
bool HaveShortPosition;
double StopLoss; // Not actual stop-loss - just a potential loss of MM estimation.

// Trade virtualization for Z-Score optimization:
bool   TradeBlock = false; // Blocks real trading, allowing virtual.
int    VirtualDirection;
bool   VirtualOpen = false;
double VirtualOP; // Open price for virtual position.
int    BlockTicket = -1; // The order ticket, after which real trading was blocked.
int fh; // File handle for saving and loading virtual trading data.

void OnInit()
{
    LoadFile();
    fh = FileOpen(FileName, FILE_WRITE | FILE_BIN);
}

void OnTick()
{
    if ((!IsTradeAllowed()) || (IsTradeContextBusy()) || (!IsConnected()) || ((!MarketInfo(Symbol(), MODE_TRADEALLOWED)) && (!IsTesting()))) return;

    // Trade only if new bar has arrived.
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

    // Virtual trading - blocking trading following a profitable trade.
    // Positive Z-Score means that losers are likely to be followed by winners and vice versa.
    if (!TradeBlock)
    {
        int tickets[];
        int nTickets = GetHistoryOrderByCloseTime(tickets);

        if (nTickets > 0)
        {
            if (!OrderSelect(tickets[0], SELECT_BY_TICKET))
            {
                int e = GetLastError();
                Print("OrderSelect Error: ", e);
                return;
            }
            if ((OrderProfit() > 0) && (OrderTicket() != BlockTicket))
            {
                TradeBlock = true;
                BlockTicket = OrderTicket();
                SaveFile();
                if (!Mute) Print("Real trading blocked on: ", tickets[0], " ", OrderOpenPrice(), " ", OrderProfit());
            }
        }
    }

    if (Bullish)
    {
        if (!HaveLongPosition) fBuy();
    }
    else if (Bearish)
    {
        if (!HaveShortPosition) fSell();
    }
    return;
}

//+------------------------------------------------------------------+
//| Check what position is currently open.                           |
//+------------------------------------------------------------------+
void GetPositionStates()
{
    if (TradeBlock) // Virtual Check
    {
        if (VirtualOpen)
        {
            if (VirtualDirection == OP_BUY)
            {
                HaveLongPosition = true;
                HaveShortPosition = false;
            }
            else if (VirtualDirection == OP_SELL)
            {
                HaveLongPosition = false;
                HaveShortPosition = true;
            }
        }
        else
        {
            HaveLongPosition = false;
            HaveShortPosition = false;
        }
        return;
    }

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
    if (TradeBlock) // Virtual Buy
    {
        VirtualDirection = OP_BUY;
        VirtualOpen = true;
        VirtualOP = Ask;
        SaveFile();
        if (!Mute) Print("Entered Virtual Long at ", VirtualOP, ".");
        return;
    }

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
    if (TradeBlock) // Virtual Sell
    {
        VirtualDirection = OP_SELL;
        VirtualOpen = true;
        VirtualOP = Bid;
        SaveFile();
        if (!Mute) Print("Entered Virtual Short at ", VirtualOP, ".");
        return;
    }

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

    return(PositionSize);
}

//+------------------------------------------------------------------+
//| Close previous position.                                         |
//+------------------------------------------------------------------+
void ClosePrevious()
{
    if (TradeBlock) // Virtual Exit
    {
        if (VirtualOpen)
        {
            if (VirtualDirection == OP_BUY)
            {
                // We lost, so the virtual trading can be turned off.
                if (Bid < VirtualOP) TradeBlock = false;
                if (!Mute) Print("Closed Virtual Long at ", Bid, " with Open at ", VirtualOP);
            }
            else if (VirtualDirection == OP_SELL)
            {
                // We lost, so the virtual trading can be turned off.
                if (Ask > VirtualOP) TradeBlock = false;
                if (!Mute) Print("Closed Virtual Short at ", Ask, " with Open at ", VirtualOP);
            }
            VirtualDirection = -1;
            VirtualOpen = false;
            VirtualOP = 0;
            SaveFile();
        }
        return;
    }

    int total = OrdersTotal();
    for (int i = 0; i < total; i++)
    {
        if (!OrderSelect(i, SELECT_BY_POS)) continue;
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
//| Saves Virtual Trading data to a file.                            |
//+------------------------------------------------------------------+
void SaveFile()
{
    // Need it to overwrite the data, not to append it each time we save.
    FileSeek(fh, 0, SEEK_SET);
    FileWriteInteger(fh, TradeBlock, CHAR_VALUE);
    FileWriteInteger(fh, VirtualDirection, CHAR_VALUE);
    FileWriteInteger(fh, VirtualOpen, CHAR_VALUE);
    FileWriteDouble(fh, VirtualOP, DOUBLE_VALUE);
    FileWriteInteger(fh, BlockTicket, LONG_VALUE);
}

//+------------------------------------------------------------------+
//| Loads Virtual Trading data from a file.                          |
//+------------------------------------------------------------------+
void LoadFile()
{
    fh = FileOpen(FileName, FILE_READ | FILE_BIN);
    if (fh < 0)
    {
        int err = GetLastError();
        if (err == 4103) Print("No saved file to load.");
        else Print(ErrorDescription(GetLastError()));
        return;
    }
    TradeBlock = FileReadInteger(fh, CHAR_VALUE);
    VirtualDirection = FileReadInteger(fh, CHAR_VALUE);
    VirtualOpen = FileReadInteger(fh, CHAR_VALUE);
    VirtualOP = FileReadDouble(fh, DOUBLE_VALUE);
    BlockTicket = FileReadInteger(fh, LONG_VALUE);
    Print("Loaded virtual trading data. TradeBlock = ", TradeBlock, " VirtualDirection = ", VirtualDirection, " VirtualOpen = ", VirtualOpen, " VirtualOP = ", VirtualOP, " BlockTicket = ", BlockTicket);
    FileClose(fh);
}

//+------------------------------------------------------------------+
//| Order History Sorting Function by WHRoeder:                      |
//| http://www.mql4.com/users/WHRoeder                               |
//+------------------------------------------------------------------+
int GetHistoryOrderByCloseTime(int& tickets[], int dsc = 1)
{
    /* http://forum.mql4.com/46182 zzuegg says history ordering "is not reliable
     * (as said in the doc)" [not in doc] dabbler says "the order of entries is
     * mysterious (by actual test)" */

    int nOrders = 0;
    datetime OCTs[];

    for (int iPos = OrdersHistoryTotal() - 1; iPos >= 0; iPos--)
    {
        if ((OrderSelect(iPos, SELECT_BY_POS, MODE_HISTORY))  // Only orders w/
                &&  (OrderMagicNumber() == Magic)             // my magic number
                &&  (OrderSymbol()      == Symbol())             // and my pair.
                &&  (OrderType()        <= OP_SELL) // Avoid cr/bal forum.mql4.com/32363#325360
           )
        {
            int nextTkt = OrderTicket();
            datetime nextOCT = OrderCloseTime();
            nOrders++;
            ArrayResize(tickets, nOrders);
            ArrayResize(OCTs, nOrders);
            // Insertn sort.
            int iOrders;
            for (iOrders = nOrders - 1; iOrders > 0; iOrders--)
            {
                datetime prevOCT = OCTs[iOrders - 1];
                if ((prevOCT - nextOCT) * dsc >= 0) break;

                int prevTkt = tickets[iOrders - 1];
                tickets[iOrders] = prevTkt;
                OCTs[iOrders] = prevOCT;
            }
            tickets[iOrders] = nextTkt;
            OCTs[iOrders] = nextOCT; // Insert.
        }
    }
    return(nOrders);
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