<upstream>0.9.0-rc.3</upstream>

Speaches is a self-hosted speech server with an OpenAI-compatible API. It
provides speech to text (transcription and translation) and text to speech,
and can act as a drop-in backend for tools that already speak the OpenAI
audio API.

## What it does

- Speech to text using faster-whisper (CTranslate2), through the
  `/v1/audio/transcriptions` and `/v1/audio/translations` endpoints.
- Text to speech using Kokoro and Piper voices, through `/v1/audio/speech`.
- A realtime API at `/v1/realtime` over WebSocket. Upstream also offers a
  WebRTC transport for this endpoint, but WebRTC is not supported through
  the platform proxy because it depends on UDP; use the WebSocket transport
  instead.
- A small web playground for trying transcription, synthesis, and audio
  chat without writing any code.

## Performance

This package runs on CPU only, because Cloudron does not offer GPU
passthrough. Small and distilled Whisper models transcribe short and medium
audio workably on CPU; large models and long files are slow. Exact
throughput figures for this package are measured on real hardware rather
than assumed, and are recorded in the package documentation once
available. Treat any number quoted elsewhere as a starting estimate, not a
guarantee.

## About the upstream project

Speaches (formerly faster-whisper-server) is a widely used open source
project, with thousands of stars and a large number of image pulls, but
development has been quiet since April 2026: the sole maintainer has not
published a release in 2026, and community issues note the slow pace
directly. This is not a project that is broken or abandoned in a technical
sense; the exact version packaged here was verified end to end, on CPU,
before release. Treat it as a stable, working release from a project
between periods of active maintenance, and expect any upstream fix for a
newly found problem to take time to arrive, if it arrives at all.

## Licence

Speaches is MIT licensed. See LICENSE for the full text.
