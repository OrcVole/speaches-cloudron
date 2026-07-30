# ADR 0004: model storage on persistentDirs, re-download as restore

Status: proposed (architect skeleton, 2026-07-30). Straight crib from vLLM
ADR 0004; highest-confidence decision in the set. Adopted into repo at
phase 2; operator-approved where marked.

## Context

Models are multi-gigabyte, fully reproducible from Hugging Face, and
downloaded on demand at runtime (probe: POST /v1/models/{id} downloads;
requests trigger load; per-type idle TTLs unload). Backing them up is waste,
and worse: the live rsync backup walk over churning download temp files can
abort the entire server backup run (platform facts; digest 2.7, 11.2).
persistentDirs content survives restart and update, survives in-place
restore, and starts empty only on clone or fresh install (field guide
gotcha 71) — and re-download is the correct restore behaviour for a cache.

rc3 adds preload_models (config list, default empty): the package can warm
the default STT and TTS models at boot rather than on first request.

## Decision (proposed)

- /var/lib/speaches on persistentDirs; HF_HOME=/var/lib/speaches/hf.
  Mechanism confirmed: upstream reads huggingface_hub's HF_HUB_CACHE
  constant, which derives from HF_HOME; upstream sets neither, so the
  redirect is clean. Upstream pre-creates the default cache dir to dodge
  root-owned-volume permission errors; our start.sh chown makes that moot.
- PRELOAD_MODELS caveat (upstream recon): the lifespan hook downloads each
  listed model BEFORE the port binds and the process EXITS if any download
  fails. Consequences: first boot with preload is download-bound (the
  ADR 0003 /healthz shim covers it) and a hard registry outage produces a
  visible crash loop with clear logs rather than a silent degrade;
  acceptable, documented in DEBUGGING.
- XDG_CACHE_HOME and any other cache envs redirected under /app/data/cache
  (digest 2.9).
- No backupCommand or restoreCommand: re-download is the restore (digest
  2.4, the named vLLM precedent).
- API key and package config on /app/data (backed up).
- minBoxVersion 9.1.0 (forced twice over: persistentDirs, and the versions
  channel iconUrl floor; digest 7.3).
- Package default models preloaded via preload_models: one small STT model
  and one TTS voice pack [exact ids from upstream recon; candidates:
  Systran/faster-distil-whisper-large-v3 is what upstream docs use for
  integrations, but size versus CPU speed says start smaller, for example
  Systran/faster-whisper-small; TTS speaches-ai Kokoro repo id per docs].
  Operator-overridable via the package settings env (ADR 0006).

## Consequences

- Backups stay small and fast and can never be aborted by cache churn.
- A clone or fresh restore boots with an empty cache: with preload_models
  set, first boot downloads the defaults in the background while /healthz
  is already green; first requests during that window are slow or 4xx
  [verify behaviour when a request names a model mid-download].
- The cache path must be right in v1: changing persistentDirs later costs
  an uninstall and reinstall (gotcha 55).

## Executor verification hooks

- [ ] Gate 3 proves all three branches: update preserves cache; in-place
      restore preserves cache; clone starts empty and re-downloads to a
      working state (digest 2.5, 11.7).
- [ ] Confirm HF_HOME is respected by every engine (faster-whisper via
      huggingface_hub, kokoro_onnx, piper): download one of each, then
      find /var/lib/speaches -newer marker.
- [ ] Measure cache size for the default model set; document expected disk
      use in README and POSTINSTALL.
