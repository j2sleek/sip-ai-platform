# Tool Specification

## Purpose

Tools allow the AI agent to perform actions outside the conversation.

## Contract

Each tool must expose:

```text
name
description
input_schema
execute
timeout
authorization requirements
```

## Example Tools

### run_n8n_workflow

Purpose:

Run an approved n8n workflow.

Input:

```json
{
  "workflow": "daily-market-report",
  "parameters": {}
}
```

### capture_chart

Purpose:

Call ChartCapture API.

Input:

```json
{
  "symbol": "BTCUSDT",
  "timeframe": "1h",
  "exchange": "binance"
}
```

### get_market_data

Purpose:

Retrieve market data from an approved API.

## Rules

- Tools must validate input.
- Tools must enforce timeouts.
- Tools must return structured results.
- Tool errors must not crash the call session.
- Sensitive credentials are never exposed to the LLM.
- Destructive tools require explicit confirmation.
