# Control API Specification

## Health

```http
GET /health
```

Returns service health.

## Readiness

```http
GET /ready
```

Checks required dependencies.

## Create Outbound Call

```http
POST /api/v1/calls
```

Request:

```json
{
  "destination": "1001",
  "agent_id": "personal-assistant",
  "context": {
    "reason": "daily briefing"
  }
}
```

Response:

```json
{
  "call_id": "uuid",
  "status": "initiating"
}
```

## Get Call

```http
GET /api/v1/calls/:call_id
```

## Hang Up

```http
POST /api/v1/calls/:call_id/hangup
```

## Call Events

Internal event types:

```text
call.created
call.ringing
call.answered
call.media_connected
call.user_started_speaking
call.user_stopped_speaking
agent.started
agent.thinking
agent.tool_started
agent.tool_completed
agent.speaking
call.ended
call.failed
```

All events should include:

```text
call_id
session_id
timestamp
event_type
metadata
```
