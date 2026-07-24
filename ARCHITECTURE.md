# SIP AI Platform — Architecture

## Purpose

A self-hosted, modular AI voice platform where Linphone users can call an AI agent and the AI agent can initiate calls back to them.

The architecture deliberately separates:

- Telephony and SIP
- Real-time call orchestration
- Media transport
- AI inference
- Agent/tool execution
- Existing business APIs and automation

## Core Architecture

```text
Linphone
   |
   | SIP/RTP
   v
Asterisk / PJSIP
   |
   | ARI call control + media interface
   v
Elixir/OTP Real-Time Core
   |
   +--> Call/session supervision
   +--> Media coordination
   +--> Agent orchestration
   +--> Tool routing
   +--> Observability
   |
   +------------------+
   |                  |
   v                  v
Python AI Services    Node.js/TypeScript Services
   |                  |
   +--> Whisper       +--> ChartCapture API
   +--> Ollama        +--> Existing APIs
   +--> Piper         +--> TypeScript integrations
   |
   v
n8n / Supabase / External APIs
```

## Technology Responsibilities

### Asterisk

Owns:

- SIP registration
- PJSIP endpoints
- Dial plans
- Call setup and teardown
- SIP/RTP handling
- PSTN/SIP trunk integration when added
- DTMF
- Telephony security

Asterisk must not contain AI business logic.

### Elixir/OTP

Owns:

- Call lifecycle
- Per-call session processes
- Supervision trees
- Real-time orchestration
- ARI integration
- Media session coordination
- Agent session coordination
- Barge-in/cancellation state
- Tool execution orchestration
- Fault isolation
- Concurrency
- Control API
- Observability

### Python

Owns:

- Speech-to-text
- Local LLM inference adapters where appropriate
- Text-to-speech
- ML/audio processing
- GPU/CPU optimized inference

Python services must expose stable APIs and must not own SIP state.

### Node.js/TypeScript

Owns:

- Existing ChartCapture API
- Browser automation
- TypeScript-first external API integrations
- Services already implemented in the Node ecosystem
- Optional future SDKs and integration services

Node services must be callable by Elixir through explicit APIs.

### n8n

Owns:

- Business automation
- Scheduled workflows
- External SaaS integrations
- Notifications
- Multi-step workflows

n8n is an integration layer, not part of the real-time call loop unless explicitly required.

## Design Principles

1. Telephony is independent from AI.
2. AI inference is independent from telephony.
3. Every active call has an isolated session.
4. Every external dependency has a timeout.
5. Every resource has cleanup logic.
6. Failures are isolated and supervised.
7. Provider implementations are replaceable.
8. No vendor-specific AI API is required by the core architecture.
9. The core must work with local/free software first.
10. Production deployment must not depend on Termux-specific behavior.

## Deployment Modes

### Development

```text
Android / Termux or Ubuntu workstation
    |
    +-- Asterisk
    +-- Elixir
    +-- Python AI services
    +-- Node.js services
    +-- n8n
```

### Production

```text
Ubuntu VPS
    |
    +-- Asterisk
    +-- Elixir OTP release
    +-- Python AI services
    +-- Node.js services
    +-- PostgreSQL/Supabase
    +-- n8n
```

AI inference may later move to a separate GPU machine without changing the telephony architecture.
