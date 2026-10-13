# Voice Communication with OpenCode Explained

## Can OpenCode handle text shared during a call while responding verbally?

Short answer: **Yes, but it depends on how the text is shared.**

## Current Architecture (Brain/Body Split)

In this design, **OpenCode is the brain**. It connects to the system via MCP (telephony_mcp). It sees and controls calls using tools, but it does *not* automatically receive arbitrary text unless you feed it.

```
You (on call) speak → STT → Transcribed text → Appears in transcript
OpenCode (brain) sees transcript via get_transcript/wait_for_input → Reasons → speak() → TTS → Plays to call
```

## What happens if you say "I'm having an error in the cass app, I just sent you the error output, what is wrong?"

If you **say this verbally** on the call, STT transcribes it. OpenCode will see that utterance (via transcript/events), and can respond verbally via `speak()` tool.

If you **send the error text separately** (paste in chat, upload file, send message outside the call audio), that text does NOT automatically go into the call transcript. OpenCode needs to receive it.

## How to share text during a live call so OpenCode sees it

Since OpenCode is connected via MCP and also has access to files/system, you have options:

### Option 1: Read it aloud (simplest)
Speak the error - works with current flow.

### Option 2: Paste/share with OpenCode context
If you're interacting with OpenCode directly (the agent session), you can paste the error in that same session. OpenCode will have context and can still call `speak()` via MCP to respond verbally on the call.

### Option 3: Upload file
OpenCode can read files (`cat`, tools) - you can save error to file and tell OpenCode "read /tmp/error.txt" during the conversation. It will process and respond verbally.

### Option 4: Extend the system
Add a tool to inject text into the current call's context (e.g., `inject_message` or allow posting to call events). This way text becomes part of conversation.

## Yes, it can handle both simultaneously

If OpenCode is actively managing the call (has an active session with the call), it can:
1. Receive text input (from your message/file in its context)
2. Reason about it while the call is ongoing
3. Call `speak()` to respond verbally in real-time
4. Still monitor transcript for new spoken input (barge-in supported)

So the answer is: **Yes. OpenCode can view the text you share in its session AND continue handling the ongoing voice call, responding verbally through TTS.** The voice call is just another channel it controls via MCP tools.
