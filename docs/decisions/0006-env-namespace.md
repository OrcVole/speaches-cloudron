# ADR 0006: environment namespace and settings surface

Status: proposed (architect skeleton, 2026-07-30). Adopted into repo at
phase 2; operator-approved where marked.

## Context

Upstream reads UNPREFIXED environment variables matching its pydantic
config field names: API_KEY works, SPEACHES_API_KEY is silently ignored
(probed on both 0.8.3 and 0.9.0-rc.3). The field set on rc3, from the boot
config dump: stt_model_ttl, tts_model_ttl, vad_model_ttl, api_key,
log_level, host, port, allow_origins, enable_ui, whisper.*,
loopback_host_url, chat_completion_base_url, chat_completion_api_key,
unstable_ort_opts, otel_exporter_otlp_endpoint, otel_service_name,
preload_models. Generic names (host, port, log_level, api_key) are exactly
the names other software and platforms also use: the collision surface of
gotcha 85, inverted. vLLM over-claimed a namespace; Speaches claims none.

## Decision (proposed)

- Package-defined operator settings use the SPEECH_ prefix (no upstream
  field begins with speech_; the obvious future upstream prefix would be
  SPEACHES_, which we deliberately avoid so a future upstream adoption of
  it cannot collide with us). Initial set:
  SPEECH_STT_MODEL, SPEECH_TTS_MODEL, SPEECH_TTS_VOICE (preload and
  documented defaults), SPEECH_EXTRA_PRELOAD (comma list appended to
  preload_models), SPEECH_UI (on/off, maps to enable_ui, default per
  ADR 0005 outcome).
- Genuine upstream settings pass through under their real unprefixed names,
  set by start.sh only where the package must force them. Resolved by
  source reading (config.py): bind host and port are pydantic field
  ALIASES, so UVICORN_HOST=127.0.0.1 and UVICORN_PORT=8001 are the only
  working names (plain HOST and PORT do nothing); nested fields use double
  underscore (WHISPER__COMPUTE_TYPE and friends); list fields take JSON
  (PRELOAD_MODELS='["Systran/faster-whisper-small", ...]', same form as
  ALLOW_ORIGINS). Also forced: API_KEY (from keys.env), ENABLE_UI (from
  SPEECH_UI), LOG_LEVEL=info (the debug default dumps the whole config to
  logs), and the telemetry opt-outs already present in the upstream image
  (HF_HUB_DISABLE_TELEMETRY, DO_NOT_TRACK, GRADIO_ANALYTICS_ENABLED=False,
  PYANNOTE_METRICS_ENABLED=0).
- One more reason SPEECH_ beats SPEACHES_ as our prefix: upstream already
  uses SPEACHES_BASE_URL (their CLI client) and SPEACHES_LOG_LEVEL (an
  acknowledged hack in main.py error handling). The SPEACHES_ namespace is
  partially occupied; ours is not.
- HF_TOKEN passes straight through untouched if the operator sets it
  (gated Hugging Face models), mirroring vLLM.
- otel_exporter_otlp_endpoint stays unset in v1; noted as a wiring
  opportunity to the observability estate later.

## Consequences

- No package variable can ever shadow an upstream field silently; every
  forced upstream var is set explicitly in start.sh with a comment naming
  the upstream field it drives.
- A future upstream SPEACHES_ prefix adoption costs us nothing.

## Executor verification hooks

- [ ] Empirically confirm each forced env name lands in the boot config
      dump on rc3 (set a sentinel value, grep the log), especially the
      list-valued PRELOAD_MODELS and nested whisper.* fields.
- [ ] Confirm LOG_LEVEL=info suppresses the config dump; if it does not,
      assess what leaks at info level (the api key prints as SecretStr
      masked, verify it stays masked everywhere).
- [ ] AGENTS.md carries the settled env mapping table like vLLM's.
