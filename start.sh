#!/bin/bash
#
# Cloudron entrypoint for Speaches (CPU backend).
#
# Runs as root, seeds /app/data and the persistentDirs model cache,
# generates and persists a single API key on first boot, exports the
# package-forced settings, starts the ingress nginx front end, then
# drops to the cloudron user and execs the application. Every
# package-emitted log line is prefixed "==>" so logs are greppable.
# See docs/decisions/0003 (ingress), 0004 (model storage), 0005 (auth
# topology), 0006 (env namespace).

set -euo pipefail

# 1. Variables: paths and ports.
CODE=/app/code
DATA=/app/data
VENV="${CODE}/venv"

SECRETS_DIR="${DATA}/.secrets"
KEYS_ENV="${SECRETS_DIR}/keys.env"

# Model weights are multi-gigabyte, fully reproducible from Hugging
# Face, and deliberately excluded from backup (ADR 0004): persistentDirs,
# not /app/data. Re-download is the restore.
MODELS_DIR=/var/lib/speaches
HF_DIR="${MODELS_DIR}/hf"      # HF_HOME
CACHE_DIR="${DATA}/cache"      # XDG_CACHE_HOME (small, backed up on /app/data)

NGINX_RUN=/run/nginx

# nginx owns the manifest httpPort; the application binds loopback-only
# behind it (ADR 0003).
PUBLIC_PORT=8000
APP_PORT=8001

echo "==> [start] speaches ${UPSTREAM_VERSION:-unknown} (cpu) booting"

# 2. Ownership and layout, EVERY boot, not only first run: a restore
#    drifts ownership and modes, and the persistentDirs mount arrives
#    root-owned (AGENTS.md golden rule 3).
#    The "hub" subdirectory is created explicitly, not just HF_HOME:
#    huggingface_hub derives HF_HUB_CACHE as ${HF_HOME}/hub and raises
#    CacheNotFound from any model listing call if that path is absent,
#    which surfaces as a 500 on GET /v1/models on a fresh install.
echo "==> [start] preparing ${DATA}, ${MODELS_DIR} and ${NGINX_RUN}"
mkdir -p "${SECRETS_DIR}" "${HF_DIR}/hub" "${CACHE_DIR}" \
         "${NGINX_RUN}/body" "${NGINX_RUN}/proxy" "${NGINX_RUN}/fastcgi" \
         "${NGINX_RUN}/uwsgi" "${NGINX_RUN}/scgi"
chown -R cloudron:cloudron "${DATA}" "${MODELS_DIR}" "${NGINX_RUN}"
chmod 0700 "${SECRETS_DIR}"

# 3. Idempotent API key. First boot only: generate it. Never overwrite
#    an existing one; integrators hold it, and a silent reseed only
#    breaks them without recovering anything (golden rule 4: fail loud,
#    never silently regenerate a secret).
if [[ ! -f "${KEYS_ENV}" ]]; then
  echo "==> [start] first run: generating API key"
  GEN_KEY="$(openssl rand -hex 32)"
  ( umask 077; cat > "${KEYS_ENV}" <<EOF
# Speaches API key, generated on first boot. Treat as a secret.
#
# Stored here as SPEACHES_API_KEY, a deliberately prefixed name.
# Upstream itself reads the unprefixed API_KEY (docs/decisions/0006),
# but this file is package state, not upstream config: a prefixed name
# keeps a bare "cat" of this file self-describing, and keeps upstream's
# own namespace unpolluted. start.sh is the one place that bridges the
# two names, exporting API_KEY from this value on every boot.
#
# Send it as: Authorization: Bearer <key>
SPEACHES_API_KEY=${GEN_KEY}
EOF
  )
  unset GEN_KEY
  echo "==> [start] API key stored at ${KEYS_ENV}"
else
  echo "==> [start] existing API key found"
fi
# Re-assert ownership and mode every boot, regardless of the branch
# above: a restore returns keys.env as 0644/root.
chown cloudron:cloudron "${KEYS_ENV}"
chmod 0600 "${KEYS_ENV}"

# 4. Load the key and bridge it onto upstream's own field name.
# shellcheck disable=SC1090,SC1091
set -a; . "${KEYS_ENV}"; set +a
# `set -a` also exports SPEACHES_API_KEY itself while sourcing; harmless
# by design (ADR 0006: upstream ignores env names it does not
# recognise), and it keeps the process environment as self-describing
# as the file.
export API_KEY="${SPEACHES_API_KEY}"

# 5. Forced upstream settings. Every var below is forced because the
#    package must control it; each comment names the upstream config
#    field it drives (docs/decisions/0006).
export UVICORN_HOST=127.0.0.1        # host: pydantic alias; plain HOST does nothing
export UVICORN_PORT="${APP_PORT}"    # port: pydantic alias; plain PORT does nothing
export LOG_LEVEL=info                # log_level: upstream default "debug" dumps the whole config
# loopback_host_url: MANDATORY. Without it, Gradio derives its self-call
# URL from the inbound Host header, so an external port that differs
# from the internal one (8000 vs 8001 here) breaks every UI action even
# with a valid key. Proven empirically; see phase-notes/phase-1-proofs.md.
export LOOPBACK_HOST_URL="http://127.0.0.1:${APP_PORT}"
export HF_HOME="${HF_DIR}"           # hf_home, via huggingface_hub's HF_HUB_CACHE derivation
export XDG_CACHE_HOME="${CACHE_DIR}" # generic cache redirect, off the read-only root filesystem
# Telemetry opt-outs, already present in the upstream image; carried
# forward explicitly so a future base image change cannot lose them.
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export GRADIO_ANALYTICS_ENABLED=False
export PYANNOTE_METRICS_ENABLED=0
# HF_TOKEN (gated Hugging Face models): operator-set only, in the app's
# own environment. Passes through untouched; no indirection needed here.

# 6. Package settings, SPEECH_ prefix (docs/decisions/0006). Booleans
#    accept on/off/true/false case-insensitively; anything unrecognised
#    (including empty) degrades to the documented default rather than
#    silently disabling a feature.
is_off() {
  case "${1,,}" in
    off|false) return 0 ;;
    *) return 1 ;;
  esac
}

SPEECH_UI="${SPEECH_UI:-on}"
if is_off "${SPEECH_UI}"; then
  export ENABLE_UI=false
else
  export ENABLE_UI=true
fi

# Defaults match the package model set recorded in ADR 0004;
# operator-overridable.
SPEECH_STT_MODEL="${SPEECH_STT_MODEL:-Systran/faster-whisper-small}"
SPEECH_TTS_MODEL="${SPEECH_TTS_MODEL:-speaches-ai/Kokoro-82M-v1.0-ONNX}"
# Not passed to the server anywhere: used only in documentation and the
# postinstall text, so operator-facing text names one coherent default
# voice instead of leaving it to upstream's own per-request default.
SPEECH_TTS_VOICE="${SPEECH_TTS_VOICE:-af_heart}"
SPEECH_EXTRA_PRELOAD="${SPEECH_EXTRA_PRELOAD:-}"
SPEECH_PRELOAD="${SPEECH_PRELOAD:-on}"

# preload_models: upstream downloads every listed model BEFORE binding
# the port and EXITS if any download fails (ADR 0004). SPEECH_PRELOAD=off
# is the escape hatch for a rig with no registry access; nginx's static
# /healthz, never proxied to the app, is what keeps the platform's
# restart-loop check happy during the download window either way.
if is_off "${SPEECH_PRELOAD}"; then
  echo "==> [start] SPEECH_PRELOAD is off: skipping model preload"
else
  PRELOAD_MODELS="$("${VENV}/bin/python3" - \
      "${SPEECH_STT_MODEL}" "${SPEECH_TTS_MODEL}" "${SPEECH_EXTRA_PRELOAD}" <<'PY'
import json
import sys

stt, tts, extra = sys.argv[1], sys.argv[2], sys.argv[3]
models = [stt, tts] + [m.strip() for m in extra.split(",") if m.strip()]
print(json.dumps(models))
PY
  )"
  export PRELOAD_MODELS
fi

# 7. Threads, bound to the cgroup CPU allotment rather than host nproc
#    (cribbed from the vLLM package's start.sh). Unbounded OMP threads
#    scale to every host core and blow the memory limit during load.
CPUS="$(nproc 2>/dev/null || echo 2)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CQ CP < /sys/fs/cgroup/cpu.max || true
  if [[ "${CQ:-max}" != "max" && "${CP:-0}" -gt 0 ]]; then
    C=$(( CQ / CP )); (( C >= 1 )) && CPUS=$C
  fi
fi
THREADS="${SPEECH_NUM_THREADS:-${CPUS}}"
(( THREADS < 1 )) && THREADS=1
export OMP_NUM_THREADS="${THREADS}"
export MKL_NUM_THREADS="${THREADS}"

# 8. Informational logging only. Never the key itself, presence only.
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  echo "==> [start] cgroup memory.max=$(cat /sys/fs/cgroup/memory.max) bytes"
fi
echo "==> [start] ui        : ${ENABLE_UI}"
echo "==> [start] stt model : ${SPEECH_STT_MODEL}"
echo "==> [start] tts model : ${SPEECH_TTS_MODEL} (voice ${SPEECH_TTS_VOICE})"
[[ -n "${SPEECH_EXTRA_PRELOAD}" ]] && echo "==> [start] extra preload: ${SPEECH_EXTRA_PRELOAD}"
if is_off "${SPEECH_PRELOAD}"; then
  echo "==> [start] preload   : off"
else
  echo "==> [start] preload   : on ${PRELOAD_MODELS}"
fi
echo "==> [start] threads   : ${THREADS} (omp/mkl)"
echo "==> [start] api key   : $( [[ -s "${KEYS_ENV}" ]] && echo 'present' || echo 'MISSING' )"

# 9. Launch. model_aliases.json and realtime-console/dist are read by
#    the application relative to its process working directory, not via
#    the venv (confirmed against the Dockerfile and upstream source);
#    cd here so that holds regardless of whatever WORKDIR a future
#    Dockerfile edit sets.
cd "${CODE}"

echo "==> [start] starting nginx on :${PUBLIC_PORT}"
gosu cloudron:cloudron nginx -c "${CODE}/nginx.conf" &

# uvicorn is exec'd so it becomes the container's main process (PID 1's
# payload): SIGTERM reaches it directly and its exit stops the
# container. nginx above stays a background child instead: it dies with
# the container, so its static /healthz can bridge the preload download
# window but can never mask an application crash.
echo "==> [start] exec uvicorn (model preload, if any, happens now; watch these logs)"
exec gosu cloudron:cloudron "${VENV}/bin/uvicorn" --factory speaches.main:create_app
