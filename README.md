# VibeBoard Plus

macOS menu bar client for VibeBoard hardware. Audio comes from the USB device microphone.

## Build And Test

```sh
swift test
bash scripts/build_app.sh
open dist/VibeBoardPlus.app
```

The VB+ menu contains speech and accessibility authorization, automatic text input,
light semantic cleanup, copying the latest transcript, and Quit. Automatic input defaults
to on and requires accessibility permission. Supported editable fields receive partial
transcripts directly, replacing only the current dictation range. If focus, caret, or text
changes, output switches to a nonactivating floating window. Unsupported fields and missing
permission also use the window. Final text remains visible for eight seconds and can be copied.

Settings > Speech Recognition provides StepFun official API recognition. The default cloud model,
`stepaudio-2.5-asr-stream`, uses bidirectional WebSocket audio and live revised transcripts;
`step-asr-1.1-stream` handles the older incremental protocol. The non-stream models
`stepaudio-2.5-asr` and `step-asr` upload WAV audio after release. Recognition and Semantic Cleanup
have separate settings pages and independent Keychain credentials. Previously shared keys remain
available to both until replaced independently. Settings text fields support native Command-V,
selection, and undo; returning to the window preserves unsaved text.
Cloud sessions are limited to five minutes, with bounded pending audio and cancellable requests.

Light semantic cleanup can use local Apple Foundation Models or StepFun cloud chat completions.
It corrects spelling and punctuation and removes redundant speech while preserving meaning.
Unavailable engines, failures, invalid results and timeouts preserve the transcript; there is
no automatic switch from local to cloud. Local timeout is 15 seconds; cloud timeout is 30 seconds.
This machine's Apple model currently reports `modelNotReady`. StepFun needs an API key entered
in Settings and offers a cloud rewrite connection test using a fixed sample sentence.

Official schemas: https://platform.stepfun.com/docs/zh/api-reference/audio/asr-stream
and https://platform.stepfun.com/docs/zh/api-reference/chat/chat-completion-create .
Cloud request/response tests use mock networking; live API audio and rewriting still require
valid credentials and a hardware recording. The old VibeBoard relay is marked unavailable
until its different audio framing and lifecycle are verified; its key is never sent to StepFun.

## Verification: 2026-09-06

- Six debug tests passed: gzip round trips for empty, Unicode, and 100 KB payloads,
  device completion/finalizing message compatibility, transcript replacement preserving
  surrounding text, UTF-16 caret offsets, and rejection of invalid rewrite output.
- Release app built; strict code signature verification passed.
- Launched the updated app; device registration and token exchange succeeded.
- Actual USB audio produced partial and final Apple Speech transcripts.
- Fixed the device remaining in Listening: the firmware expects `event: ui_state`
  with `state: ready`, rather than `event: session_finished`. Added thinking state,
  empty/error completion, and a 12-second finalization timeout.
- After restart, logs recorded recording -> thinking -> ready; the user confirmed
  both initial screen recovery and normal completion after a new hardware recording.
- Synthetic speech through Opus encoding/decoding produced partial transcripts. A subsequent
  device recording replaced that task; the synthetic test's final result was not verified.
- Menu inspection via desktop automation timed out twice; visual and text delivery QA remain open.

## Replacement Acceptance Gaps

This version is not yet a complete replacement for VibeBoard 0.5.4.

- Validate hold/click button semantics, rapid recordings, silence, stale callbacks, and target focus changes.
- Serial ports are resolved through IOKit using USB VID/PID and serial identity. Descriptor reads,
  close, parsing and timers share the main queue; reconnect retries every two seconds and a missing
  device handshake triggers reopening. PTY tests cover handshake and reopening with partial frames.
  Partial writes and prolonged physical unplug/replug and reboot testing remain open.
- USB presence polling runs every five seconds; this does not yet verify device responsiveness.
- Registration retry and switching between different device identities need explicit lifecycle handling.
- Relay framing declares Ogg while sending individual compressed packets; verify and implement the
  server's exact audio container, end-of-audio semantics, bounded buffering, and reconnect behavior.
- Provider-specific remote protocols are not interchangeable. Unverified fallback endpoints are disabled.
- Complete persistent settings and legacy configuration migration, translation, recording export,
  firmware update with integrity verification, and launch-at-login support.
- Run real hardware end-to-end input checks and prolonged offline/reconnect tests before retiring the old app.

Runtime logs currently live at /tmp/vibeboardplus.log and include recognized text.
