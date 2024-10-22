﻿//+------------------------------------------------------------------+
//|                                                  HAN_Z-Score.mq5 |
//|                             Copyright © 2013-2022, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2013-2022, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/Heiken-Ashi-Naive/"
#property version   "1.03"

#property description "Uses Heiken Ashi candles."
#property description "Buy: Bullish HA candle, no lower wick, body longer than prev. body, prev. candle bullish."
#property description "Sell: Bearish HA candle, no upper wick, body longer than prev. body, prev. candle bearish."
#property description "Exit buy: Bearish HA candle, current candle has no upper wick, previous also bearish."
#property description "Exit sell: Bullish HA candle, current candle has no lower wick, previous also bullish."
#property description "You can choose either direct trading (buy on bullish) or inverted (sell on bullish)."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

input group "Main"
input bool Inverted = true; // Inversion: If true, sells on Bullish signals, buys on Bearish.

input group "Money management"
input double Lots = 0.1; // Lots: Basic lot size.
input bool MM  = false; // MM: If true - ATR-based position sizing.
input int ATR_Period = 20;
input double ATR_Multiplier = 1;
input double Risk = 2; // Risk: Risk tolerance in percentage points.
input double FixedBalance = 0; // FixedBalance: If >= 0, will use it instead of actual balance.
input double MoneyRisk = 0; // MoneyRisk: Risk tolerance in base currency.
input bool UseMoneyInsteadOfPercentage = false;
input bool UseEquityInsteadOfBalance = false;

input group "Miscellaneous"
input string OrderComment = "HAN";
input int Slippage = 100; // Slippage: Tolerated slippage in points.
input bool Mute = false;
input string FileName = "HAN_vt.dat";

// Main trading objects:
CTrade *Trade;
CPositionInfo PositionInfo;

// Global variables:
// Common:
ulong LastBars = 0;
bool HaveLongPosition;
bool HaveShortPosition;
double StopLoss; // Not the actual stop-loss - just a potential loss of MM estimation.

// Indicator handles:
int HeikenAshiHandle;
int ATRHandle;

// Buffers:
double HAOpen[];
double HAClose[];
double HAHigh[];
double HALow[];

// Trade virtualization for Z-Score optimization.
struct virtual_trading
{
    bool               TradeBlock; // Blocks real trading, allowing virtual.
    ENUM_POSITION_TYPE VirtualDirection;
    bool               VirtualOpen;
    double             VirtualOP; // Open price for virtual position.
    long               BlockTicket; // Order number, after which real trading was blocked.
};
virtual_trading VirtualTrading;
int fh; // File handle for saving and loading virtual trading data.

void OnInit()
{
    // Initialize the Trade class object.
    Trade = new CTrade;
    Trade.SetDeviationInPoints(Slippage);
    HeikenAshiHandle = iCustom(_Symbol, _Period, "Examples\\Heiken_Ashi");
    ATRHandle = iATR(NULL, 0, ATR_Period);

    // Virtual trading initialization.
    VirtualTrading.TradeBlock = false;
    VirtualTrading.VirtualOpen = false;
    VirtualTrading.VirtualOP = 0;
    if (FileIsExist(FileName, FILE_COMMON)) LoadFile();
    fh = FileOpen(FileName, FILE_WRITE | FILE_BIN | FILE_COMMON);
}

void OnDeinit(const int reason)
{
    delete Trade;
}

void OnTick()
{
    if ((!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) || (!TerminalInfoInteger(TERMINAL_CONNECTED)) || (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)) return;

    int bars = Bars(_Symbol, _Period);

    // Trade only if new bar has arrived.
    if (LastBars != bars) LastBars = bars;
    else return;

    // Latest two completed bars.
    if (CopyBuffer(HeikenAshiHandle, 0, 1, 2, HAOpen) != 2) return;
    if (CopyBuffer(HeikenAshiHandle, 3, 1, 2, HAClose) != 2) return;
    // Don't need the previous candle for High/Low, but copying it anyway for the sake of code uniformity.
    if (CopyBuffer(HeikenAshiHandle, 1, 1, 2, HAHigh) != 2) return;
    if (CopyBuffer(HeikenAshiHandle, 2, 1, 2, HALow) != 2) return;

    // Getting the potential loss value based on current ATR.
    if (MM)
    {
        double ATR[1];
        if (CopyBuffer(ATRHandle, 0, 1, 1, ATR) != 1) return;
        StopLoss = ATR[0] * ATR_Multiplier;
    }

    // Close conditions.
    bool BearishClose = false;
    bool BullishClose = false;

    // Signals.
    bool Bullish = false;
    bool Bearish = false;

    // Close signals.
    // Bullish HA candle, current has no lower wick, previous also bullish.
    if ((HAOpen[1] < HAClose[1]) && (HALow[1] == HAOpen[1]) && (HAOpen[0] < HAClose[0]))
    {
        if (Inverted) BullishClose = true;
        else BearishClose = true;
    }
    // Bearish HA candle, current has no upper wick, previous also bearish.
    else if ((HAOpen[1] > HAClose[1]) && (HAHigh[1] == HAOpen[1]) && (HAOpen[0] > HAClose[0]))
    {
        if (Inverted) BearishClose = true;
        else BullishClose = true;
    }

    // First entry condition
    // Bullish HA candle, and body is longer than previous body, previous also bullish, current has no lower wick.
    if ((HAOpen[1] < HAClose[1]) && (HAClose[1] - HAOpen[1] > MathAbs(HAClose[0] - HAOpen[0])) && (HAOpen[0] < HAClose[0]) && (HALow[1] == HAOpen[1]))
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
    else if ((HAOpen[1] > HAClose[1]) && (HAOpen[1] - HAClose[1] > MathAbs(HAClose[0] - HAOpen[0])) && (HAOpen[0] > HAClose[0]) && (HAHigh[1] == HAOpen[1]))
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
    if (!VirtualTrading.TradeBlock)
    {
        // Looking back for 1 week, but in fact, 1 day would be enough.
        HistorySelect(TimeCurrent() - 7 * 24 * 3600, TimeCurrent());
        ulong deal = HistoryDealsTotal();
        deal = HistoryDealGetTicket((int)deal - 1);
        if (deal > 0)
        {
            if (HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
                if ((HistoryDealGetDouble(deal, DEAL_PROFIT) > 0) && (HistoryDealGetInteger(deal, DEAL_ORDER) != VirtualTrading.BlockTicket))
                {
                    VirtualTrading.TradeBlock = true;
                    VirtualTrading.BlockTicket = HistoryDealGetInteger(deal, DEAL_ORDER);
                    SaveFile();
                    if (!Mute) Print("Real trading blocked on: ", deal, " ", HistoryDealGetInteger(deal, DEAL_ENTRY), " ", HistoryDealGetDouble(deal, DEAL_PROFIT));
                }
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
}

//+------------------------------------------------------------------+
//| Check what position is currently open.                           |
//+------------------------------------------------------------------+
void GetPositionStates()
{
    if (VirtualTrading.TradeBlock) // Virtual Check
    {
        if (VirtualTrading.VirtualOpen)
        {
            if (VirtualTrading.VirtualDirection == POSITION_TYPE_BUY)
            {
                HaveLongPosition = true;
                HaveShortPosition = false;
            }
            else if (VirtualTrading.VirtualDirection == POSITION_TYPE_SELL)
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

    // Is there a position on this currency pair?
    if (PositionInfo.Select(_Symbol))
    {
        if (PositionInfo.PositionType() == POSITION_TYPE_BUY)
        {
            HaveLongPosition = true;
            HaveShortPosition = false;
        }
        else if (PositionInfo.PositionType() == POSITION_TYPE_SELL)
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
}

//+------------------------------------------------------------------+
//| Buy                                                              |
//+------------------------------------------------------------------+
void fBuy()
{
    double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

    if (VirtualTrading.TradeBlock) // Virtual Buy
    {
        VirtualTrading.VirtualDirection = POSITION_TYPE_BUY;
        VirtualTrading.VirtualOpen = true;
        VirtualTrading.VirtualOP = Ask;
        SaveFile();
        if (!Mute) Print("Entered Virtual Long at ", VirtualTrading.VirtualOP, ".");
        return;
    }

    Trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, LotsOptimized(), Ask, 0, 0, OrderComment);
}

//+------------------------------------------------------------------+
//| Sell                                                             |
//+------------------------------------------------------------------+
void fSell()
{
    double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);

    if (VirtualTrading.TradeBlock) // Virtual Sell
    {
        VirtualTrading.VirtualDirection = POSITION_TYPE_SELL;
        VirtualTrading.VirtualOpen = true;
        VirtualTrading.VirtualOP = Bid;
        SaveFile();
        if (!Mute) Print("Entered Virtual Short at ", VirtualTrading.VirtualOP, ".");
        return;
    }

    Trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, LotsOptimized(), Bid, 0, 0, OrderComment);
}

//+------------------------------------------------------------------+
//| Calculate position size depending on money management parameters.|
//+------------------------------------------------------------------+
double LotsOptimized()
{
    if (!MM) return Lots;

    double Size, RiskMoney, PositionSize = 0;

    // If could not find account currency, probably not connected.
    if (AccountInfoString(ACCOUNT_CURRENCY) == "") return(-1);

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountInfoDouble(ACCOUNT_EQUITY);
    }
    else
    {
        Size = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    double UnitCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int LotStep_digits = CountDecimalPlaces(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
    
    if ((StopLoss != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (StopLoss * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) PositionSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    else if (PositionSize > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) PositionSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    return PositionSize;
}

//+------------------------------------------------------------------+
//| Close open position.                                             |
//+------------------------------------------------------------------+
void ClosePrevious()
{
    if (VirtualTrading.TradeBlock) // Virtual Exit
    {
        if (VirtualTrading.VirtualOpen)
        {
            if (VirtualTrading.VirtualDirection == POSITION_TYPE_BUY)
            {
                double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
                // We lost, so the virtual trading can be turned off.
                if (Bid < VirtualTrading.VirtualOP) VirtualTrading.TradeBlock = false;
                if (!Mute) Print("Closed Virtual Long at ", Bid, " with Open at ", VirtualTrading.VirtualOP);
            }
            else if (VirtualTrading.VirtualDirection == POSITION_TYPE_SELL)
            {
                double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
                // We lost, so the virtual trading can be turned off.
                if (Ask > VirtualTrading.VirtualOP) VirtualTrading.TradeBlock = false;
                if (!Mute) Print("Closed Virtual Short at ", Ask, " with Open at ", VirtualTrading.VirtualOP);
            }
            VirtualTrading.VirtualDirection = -1;
            VirtualTrading.VirtualOpen = false;
            VirtualTrading.VirtualOP = 0;
            SaveFile();
        }
        return;
    }

    for (int i = 0; i < 10; i++)
    {
        Trade.PositionClose(_Symbol, Slippage);
        if ((Trade.ResultRetcode() != 10008) && (Trade.ResultRetcode() != 10009) && (Trade.ResultRetcode() != 10010))
            Print("Position Close Return Code: ", Trade.ResultRetcodeDescription());
        else return;
    }
}

//+------------------------------------------------------------------+
//| Saves Virtual Trading data to a file.                            |
//+------------------------------------------------------------------+
void SaveFile()
{
    // Need it to overwrite the data, not to append it each time we save.
    FileSeek(fh, 0, SEEK_SET);
    FileWriteStruct(fh, VirtualTrading, sizeof(VirtualTrading));
}

//+------------------------------------------------------------------+
//| Loads Virtual Trading data from a file.                          |
//+------------------------------------------------------------------+
void LoadFile()
{
    fh = FileOpen(FileName, FILE_READ | FILE_BIN | FILE_COMMON);
    if (fh == INVALID_HANDLE)
    {
        Print("Could not load virtual trading data: ", GetLastError());
        return;
    }
    FileReadStruct(fh, VirtualTrading, sizeof(VirtualTrading));
    Print("Loaded virtual trading data. TradeBlock = ", VirtualTrading.TradeBlock, " VirtualDirection = ", VirtualTrading.VirtualDirection, " VirtualOpen = ", VirtualTrading.VirtualOpen, " VirtualOP = ", VirtualTrading.VirtualOP, " BlockTicket = ", VirtualTrading.BlockTicket);
    FileClose(fh);
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