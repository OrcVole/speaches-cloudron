# ADR 0003: ingress shape (thin nginx, repurposed rationale)

Status: proposed (architect skeleton, 2026-07-30). Adopted into repo at
phase 2; operator-approved where marked.

## Context

The vLLM package needed nginx for immediate health during a nine-minute
port-silent warmup. Speaches does not have that problem: the probe measured
2.4 s from container start to HTTP 200 on /health with an empty model cache,
because models load on demand. The original shim rationale is gone; on
0.9.0-rc.3 /health is also open when native auth is enabled (a change from
0.8.3, where the key gated /health).

One vLLM-class case returns through the back door: PRELOAD_MODELS (which
ADR 0004 sets for the default models) is processed in the FastAPI lifespan
hook BEFORE uvicorn binds the port, and the process exits if any download
fails. A fresh install or clone therefore has a genuinely slow,
download-bound window before first bind. The /healthz carve-out below
covers exactly that window.

nginx also earns its place for other reasons:

- client_max_body_size: audio uploads are the payload. Uvicorn imposes no
  limit, but the platform proxy in front may [verify on the rig; no doctrine
  exists, digest 10.3]. In-container nginx sets an explicit, documented
  limit under our control (proposed 256m to cover roughly two hours of
  44.1 kHz 16-bit stereo wav, the honest worst common case).
- Streaming: transcription responses can stream and TTS audio streams;
  proxy_buffering off and proxy_request_buffering off end to end, with long
  read and send timeouts (600 s), mirror the proven vLLM config against the
  platform's 60 s idle cut (each streamed chunk resets the window).
- Websockets: /v1/realtime is a websocket endpoint and Gradio 5 uses
  server-sent events plus occasional websocket paths [verify which, per
  endpoint, at executor]. The vLLM nginx had no Upgrade handling; this one
  needs the standard Upgrade and Connection header block on the proxied
  location.
- A stable health carve-out: location = /healthz returning 200 directly from
  nginx keeps the manifest healthCheckPath independent of upstream auth
  changes (0.8.3 gated /health; rc3 does not; do not bet the restart loop on
  upstream keeping it open).
- A control point for the auth topology fallback (ADR 0005 option B needs a
  landing page at / if the UI is disabled).

## Empirical addendum (phase 1 proofs, 2026-07-30)

- Preload cost measured: with PRELOAD_MODELS set to one small model, first
  HTTP response came at 27.6 s against a 2.4 s empty-cache baseline. The
  /healthz carve-out below is load-bearing for fresh installs and clones.
- Gradio self-call trap: when LOOPBACK_HOST_URL is unset, the Gradio app
  builds its own backend URL from the inbound Host header, so an external
  port that differs from the internal one breaks every UI action even with
  a valid key. This nginx design (8000 external, 8001 internal) has that
  exact shape. start.sh must set LOOPBACK_HOST_URL to the internal address
  (<http://127.0.0.1:8001>), and the UI smoke must run through nginx rather
  than against uvicorn directly, or the trap stays hidden.

## Decision (proposed)

Ship the thin nginx front end on the manifest httpPort (8000 external,
uvicorn moved to 127.0.0.1:8001 internal), cribbing the vLLM nginx.conf
(temp paths under /run, error_log stderr keyword form, worker_processes 1)
plus: client_max_body_size 256m, websocket Upgrade block, /healthz static
200, proxy timeouts 600 s, buffering off both directions.

healthCheckPath: /healthz. Rationale: independent of upstream auth
behaviour; Cloudron treats 4xx as healthy so even a regression would not
loop, but a static 200 keeps the signal honest and boring.

## Consequences

- One more process in the container (worker_processes 1, negligible memory),
  started backgrounded before exec of uvicorn as PID 1 payload, so a crash
  of the app still stops the container.
- The 60 s platform cut is a documented operational fact for consumers who
  disable streaming; the checklist entry mirrors the vLLM streaming note
  with transcription phrasing.

## Executor verification hooks

- [ ] Verify the platform proxy upload limit empirically with a large file
      against the test install; record the number in DEBUGGING.md and, if
      restrictive, in four-audience-notes for team Cloudron.
- [ ] Verify /v1/realtime websocket works through platform proxy plus our
      nginx (wscat or the upstream docs example).
- [ ] Verify Gradio UI transport (SSE or websocket) works through the full
      chain, under the chosen auth topology.
- [ ] Confirm long transcription (over 60 s wall time, non-streamed) fails
      at the platform cut as predicted, and works streamed; document.
