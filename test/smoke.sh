#!/bin/bash
# test/smoke.sh: local runtime smoke test for speaches-cloudron (rootless
# podman). Boots the built image standalone, waits for the ingress health
# endpoint, and checks the auth boundary on the API.
#
# STATUS: ACTIVE since 0.1.1 (2026-09-23). Until then this script had never run to completion:
# it needed :Z on its bind mounts, a key read through the container, and a wait for the app behind
# nginx (nginx's /healthz answers long before the app has downloaded its preload model). It now also
# proves real work: Kokoro speaks a sentence and faster-whisper must hear it back, and the gradio UI
# must load with its API key script. Passes on the published 0.1.0 and on 0.1.1.
#
# Usage: test/smoke.sh [IMAGE]
#   IMAGE defaults to $SCAN_IMAGE, else the dockerImage in
#   CloudronManifest.json, else a locally tagged dev build.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 2

IMAGE="${1:-${SCAN_IMAGE:-}}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(grep -oE '"dockerImage"[[:space:]]*:[[:space:]]*"[^"]+"' CloudronManifest.json 2>/dev/null \
           | grep -oE '"[^"]+"$' | tr -d '"')"
fi
IMAGE="${IMAGE:-localhost/speaches-cloudron:dev}"

CRI="$(command -v podman || command -v docker || true)"
if [[ -z "$CRI" ]]; then
  echo "no podman or docker found; cannot run the smoke test" >&2
  exit 2
fi

if ! "$CRI" image exists "$IMAGE" 2>/dev/null && ! "$CRI" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image not present locally: $IMAGE" >&2
  echo "build it first (phase 3 onward), or pass an image ref as \$1" >&2
  exit 2
fi

NAME="speaches-smoke-$$"
DATA_DIR="$(mktemp -d)"
MODELS_DIR="$(mktemp -d)"

cleanup() {
  local status=$?
  echo "==> cleanup: stopping and removing ${NAME}, and scratch dirs"
  "$CRI" rm -f "$NAME" >/dev/null 2>&1 || true
  # Files the container wrote belong to host sub-uids: remove them inside the
  # user namespace, falling back to a plain rm when rootful.
  "$CRI" unshare rm -rf "$DATA_DIR" "$MODELS_DIR" 2>/dev/null || rm -rf "$DATA_DIR" "$MODELS_DIR"
  exit "$status"
}
trap cleanup EXIT

echo "=== boot: ${IMAGE} ==="
# /app/data (localstorage addon) and /var/lib/speaches (persistentDirs)
# both mounted as they would be on the real platform, so the container
# takes the same first-boot code path as production: seed dirs, generate
# keys.env, chown, start nginx, then exec the app.
"$CRI" run -d --name "$NAME" \
  -p "127.0.0.1::8000" \
  -v "${DATA_DIR}:/app/data:Z" \
  -v "${MODELS_DIR}:/var/lib/speaches:Z" \
  "$IMAGE" >/dev/null

# Published port is dynamic to avoid clashing with anything else running
# locally. Parsing verified empirically once this script actually runs,
# at phase 4; podman and docker both print "HOST:PORT" for `port`.
HOST_PORT="$("$CRI" port "$NAME" 8000/tcp | head -n1 | cut -d: -f2)"
if [[ -z "$HOST_PORT" ]]; then
  echo "FAIL: could not determine the published host port" >&2
  exit 1
fi
echo "  published on 127.0.0.1:${HOST_PORT}"

echo "=== wait for /healthz ==="
ready=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${HOST_PORT}/healthz" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  echo "FAIL: /healthz never returned 200 within 60s" >&2
  echo "--- container logs ---" >&2
  "$CRI" logs "$NAME" >&2 || true
  exit 1
fi
echo "OK: /healthz is up"

# /healthz is answered by nginx itself. The app behind it downloads its
# preload model before it listens (about 25 s on a fast link, first boot
# only), and nginx returns 502 for the API until then. Wait for the APP.
echo "=== wait for the app behind nginx (first boot downloads the preload model) ==="
app=0
for _ in $(seq 1 120); do
  case "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HOST_PORT}/v1/models")" in 200|401|403) app=1; break ;; esac
  "$CRI" container exists "$NAME" && [[ "$("$CRI" inspect -f "{{.State.Running}}" "$NAME")" == true ]] || { echo "FAIL: the container exited while starting" >&2; "$CRI" logs "$NAME" 2>&1 | tail -40 >&2; exit 1; }
  sleep 5
done
[[ "$app" -eq 1 ]] || { echo "FAIL: the app never answered behind nginx within 600s" >&2; "$CRI" logs "$NAME" 2>&1 | tail -30 >&2; exit 1; }
echo "OK: the app answers behind nginx"

echo "=== read the generated key (inside the container) ==="
# Read through the container, not the host path: the file belongs to the
# container's cloudron uid, which rootless podman maps to a host sub-uid, in
# a 0700 directory, so the host user cannot see it and a host-side check
# reports "never created" for a file that exists (first real run, 2026-09-23).
KEYS_ENV=/app/data/.secrets/keys.env
for _ in $(seq 1 30); do
  "$CRI" exec "$NAME" test -s "$KEYS_ENV" 2>/dev/null && break
  sleep 1
done
if ! "$CRI" exec "$NAME" test -s "$KEYS_ENV" 2>/dev/null; then
  echo "FAIL: ${KEYS_ENV} was never created" >&2
  exit 1
fi
API_KEY="$("$CRI" exec "$NAME" grep -m1 '^SPEACHES_API_KEY=' "$KEYS_ENV" | cut -d= -f2-)"
if [[ -z "$API_KEY" ]]; then
  echo "FAIL: keys.env exists but API_KEY is empty" >&2
  exit 1
fi
echo "OK: key present (value not printed)"

echo "=== auth boundary on /v1/models ==="
code_none="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/v1/models")"
code_wrong="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong-key-obviously" "http://127.0.0.1:${HOST_PORT}/v1/models")"
code_right="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${API_KEY}" "http://127.0.0.1:${HOST_PORT}/v1/models")"
echo "  no key: ${code_none}, wrong key: ${code_wrong}, right key: ${code_right}"
fail=0
[[ "$code_none"  == "403" ]] || { echo "FAIL: expected 403 with no key, got ${code_none}"; fail=1; }
[[ "$code_wrong" == "403" ]] || { echo "FAIL: expected 403 with wrong key, got ${code_wrong}"; fail=1; }
[[ "$code_right" == "200" ]] || { echo "FAIL: expected 200 with the real key, got ${code_right}"; fail=1; }

# One real synthesis and one real transcription, chained: Kokoro speaks a
# sentence and faster-whisper must hear the words back. Without this the
# test proved auth and liveness only, and a broken inference path passed
# (added 2026-09-23, with the dependency upgrades that could break it).
# One call of each: CPU inference is scarce during gates, never a retry
# storm. The first run downloads both models (about 400 MB).
AUTH=(-H "Authorization: Bearer ${API_KEY}")
BASE="http://127.0.0.1:${HOST_PORT}"
TTS_MODEL="speaches-ai/Kokoro-82M-v1.0-ONNX"
STT_MODEL="Systran/faster-whisper-tiny"
WAV="$(mktemp --suffix=.wav)"
echo "=== download ${TTS_MODEL} and ${STT_MODEL} ==="
for m in "$TTS_MODEL" "$STT_MODEL"; do
  code="$(curl -s -m 900 -o /dev/null -w '%{http_code}' -X POST "${AUTH[@]}" "${BASE}/v1/models/${m}")"
  [[ "$code" == 200 || "$code" == 201 ]] || { echo "FAIL: download ${m} returned ${code}"; fail=1; }
done
echo "=== synthesis: Kokoro speaks one sentence ==="
code="$(curl -s -m 300 -o "$WAV" -w '%{http_code}' -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${TTS_MODEL}\",\"voice\":\"af_heart\",\"response_format\":\"wav\",\"input\":\"The quick brown fox jumps over the lazy dog.\"}" \
  "${BASE}/v1/audio/speech")"
if [[ "$code" == 200 ]] && head -c 4 "$WAV" | grep -q RIFF && [[ "$(stat -c %s "$WAV")" -gt 20000 ]]; then
  echo "OK: synthesis returned a WAV of $(stat -c %s "$WAV") bytes"
else
  echo "FAIL: synthesis returned ${code}, $(stat -c %s "$WAV" 2>/dev/null || echo 0) bytes"; fail=1
fi
echo "=== transcription: faster-whisper must hear it back ==="
TEXT="$(curl -s -m 300 -X POST "${AUTH[@]}" -F "file=@${WAV}" -F "model=${STT_MODEL}" "${BASE}/v1/audio/transcriptions" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("text",""))' 2>/dev/null | tr 'A-Z' 'a-z')"
if [[ "$TEXT" == *fox* && "$TEXT" == *dog* ]]; then
  echo "OK: transcribed back as: ${TEXT}"
else
  echo "FAIL: transcription did not recover the sentence (got: '${TEXT}')"; fail=1
fi
echo "=== the web UI (gradio) loads ==="
UI="$(curl -s -m 30 "${BASE}/")"
[[ "$UI" == *gradio* ]] && echo "OK: / serves the gradio UI" || { echo "FAIL: / did not serve the gradio UI"; fail=1; }
# The playground's API key helpers live in a head script; gradio 6 drops it unless it is passed to
# mount_gradio_app, and the page still loads without it (0.1.1 build, 2026-09-23).
[[ "$UI" == *loadApiKey* ]] && echo "OK: the API key helper script is on the page" || { echo "FAIL: the API key helper script is missing from /"; fail=1; }

if [[ "$fail" -ne 0 ]]; then
  echo "==================================================="
  echo "smoke test FAILED"
  exit 1
fi
echo "==================================================="
echo "smoke test OK"
