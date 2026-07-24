# Asterisk ↔ Elixir Media Streaming Decision

## Executive Decision

Use **Asterisk ARI for call control** and initially evaluate the following media transports in this order:

1. **Asterisk WebSocket Channel Driver (`chan_websocket`)** — preferred target for modern Asterisk deployments.
2. **AudioSocket** — preferred fallback for maximum simplicity and broad version compatibility.
3. **RTP External Media** — fallback/interoperability option when required.
4. **Direct RTP/media stack in Elixir** — only when the project has a demonstrated need for custom media processing.

## Why WebSocket is the preferred target

Modern Asterisk documentation describes `chan_websocket` as a media channel driver intended to reduce the burden on ARI application developers. It supports bidirectional media, supports multiple codecs, can use TLS, accepts arbitrary packet lengths, and handles packet timing and silence generation for the application. This is particularly attractive for an Elixir application because it allows the Elixir media process to focus on application-level audio streaming instead of manually implementing RTP packet timing. The driver is available in Asterisk 20.16.0, 21.11.0, 22.6.0 and 23.0.0 release lines according to the current documentation. Verify the exact installed version before implementation. citeturn0search4turn0search12

## AudioSocket

AudioSocket is a simple TCP protocol for bidirectional real-time audio. Asterisk's `AudioSocket()` application sends and receives 16-bit, 8 kHz mono PCM by default and includes a small framing protocol. It is an excellent fallback because an Elixir service can implement a small TCP server without taking responsibility for RTP packetization and timing. It is available since Asterisk 18. citeturn0search0turn0search1

## RTP External Media

ARI External Media supports an external media channel and can place it into a bridge. The original interface uses RTP over UDP and requires the external application to handle RTP packet manipulation and timing. It remains useful for interoperability and custom media infrastructure, but it increases implementation complexity. citeturn0search5turn0search12

## ARI's role

ARI is the correct call-control boundary. It exposes channels, bridges and media resources through REST and asynchronous WebSocket events, while `Stasis()` transfers channel control to the external application. Elixir should use ARI to manage call lifecycle while the selected media transport carries audio. citeturn0search7turn0search9

## Recommended initial topology

```text
Linphone
    |
    | SIP/RTP
    v
Asterisk
    |
    +---- ARI REST/WebSocket ----> Elixir Call Supervisor
    |
    +---- WebSocket media -------> Elixir Media Session
                                      |
                                      +--> VAD
                                      +--> Python STT
                                      +--> Elixir Agent Runtime
                                      +--> Python TTS
                                      |
                                      <---- audio
```

## Important separation

Do not combine:

- SIP signaling
- ARI control
- Audio transport
- AI inference

into one module.

Use separate Elixir supervision branches:

```text
RootSupervisor
  |
  +-- AriConnection
  |
  +-- CallRegistry
  |
  +-- CallSupervisor
  |      |
  |      +-- CallSession
  |      +-- MediaSession
  |      +-- AgentSession
  |
  +-- ProviderSupervisor
  |
  +-- ToolSupervisor
```

## Media format recommendation

Start with the narrowest stable format required by the chosen transport.

For AudioSocket, use 16-bit signed PCM, mono, 8 kHz initially.

For WebSocket, select a codec supported by the installed Asterisk version and keep transcoding at the boundary. Do not introduce unnecessary resampling until a real provider requires it.

## Technical evaluation test matrix

Before production implementation, test:

| Test | WebSocket | AudioSocket | RTP |
|---|---|---|---|
| Bidirectional audio | Required | Required | Required |
| Elixir implementation complexity | Low/Medium | Low | High |
| Packet timing burden | Low | Low | High |
| Codec flexibility | High | Medium | High |
| TLS | Supported | TCP-level design required | Requires network design |
| Barge-in suitability | High | High | High |
| Debuggability | High | Very high | Medium |
| Version compatibility | Verify version | Broad | Broad |
| Recommended role | Primary | Fallback | Interop fallback |

## Final recommendation

Implement an abstraction:

```text
MediaTransport
  |
  +-- WebSocketMediaTransport
  +-- AudioSocketMediaTransport
  +-- RtpMediaTransport
```

The first production-capable adapter should be **WebSocket**, provided the deployment uses a compatible Asterisk release. The first fallback adapter should be **AudioSocket**.

The application must not leak transport-specific details into the agent layer.

## Open technical questions

Before coding the media adapter:

1. Which Asterisk version will be the baseline?
2. Does the target Termux/Ubuntu environment support the selected Asterisk build?
3. Is `chan_websocket` available and loaded?
4. Which audio format minimizes transcoding?
5. What is the measured end-to-end latency?
6. How will VAD be implemented?
7. Where will audio buffering occur?
8. How will backpressure be handled?
9. How will barge-in cancel TTS?
10. What is the maximum concurrent-call target for the first deployment?

These questions must be answered by a proof-of-concept before locking the production media contract.
