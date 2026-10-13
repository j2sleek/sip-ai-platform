# Invoking OpenCode Programmatically

## Options

### 1. OpenCode CLI (Recommended)
Use `opencode run` with --print/format. Works well for scripted invocations.

```bash
opencode run --session voice-call-123 "User said: Hello, how should I respond?"
opencode run --format json --session voice-call-123 "Continue conversation"
```

Bridge code in `apps/telephony_mcp/src/bridge-opencode.ts` provides `callOpenCode()`.

### 2. OpenCode API (if server running)
`opencode api` to talk to background server. Good for persistent sessions.

### 3. MCP (Current approach)
OpenCode acts as brain connecting to telephony_mcp - OpenCode calls MCP tools to control calls. This is the brain/body split.

## For Voice/Text Integration

To "call or text" OpenCode from the app:
- **Text**: spawn `opencode run` with message, get response
- **Voice**: transcribe speech (STT) → send to OpenCode via CLI/API → synthesize response (TTS) → play/send to call

This means reversing: platform triggers OpenCode as the reasoning engine. The current setup has OpenCode trigger the platform via MCP. Both work; choose based on use case.

### Example voice flow
```ts
const text = await stt.transcribe(audio);
const resp = await callOpenCode({ message: text, sessionId: callId });
await tts.speak(resp);
```
