# Testing Strategy

## Unit Tests

Test:

- Call state machine
- Session lifecycle
- Tool router
- Provider adapters
- Audio framing
- Configuration validation

## Integration Tests

Test:

- Elixir ↔ Asterisk
- Elixir ↔ STT
- Elixir ↔ LLM
- Elixir ↔ TTS
- Elixir ↔ n8n
- Elixir ↔ ChartCapture

## End-to-End Tests

1. Linphone registers.
2. Linphone calls AI extension.
3. Asterisk answers.
4. Elixir creates session.
5. Media connects.
6. User speaks.
7. STT transcribes.
8. Agent responds.
9. TTS synthesizes.
10. Audio reaches Linphone.
11. User hangs up.
12. All resources clean up.

## Failure Tests

- Asterisk unavailable
- ARI disconnected
- Media transport disconnected
- STT timeout
- LLM timeout
- TTS timeout
- Tool timeout
- User interrupts AI
- User hangs up during TTS
- AI service crashes
- Concurrent calls

## Performance Tests

Measure:

- Calls per second
- Concurrent calls
- Memory per call
- CPU per call
- Media latency
- STT latency
- LLM latency
- TTS latency
- End-to-end latency

## Acceptance Target

The initial prototype should prioritize correctness and observability.

Performance optimization begins only after baseline measurements exist.
