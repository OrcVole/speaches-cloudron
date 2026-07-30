#!/bin/bash
# test/smoke.sh: local runtime smoke test for speaches-cloudron (rootless
# podman). Boots the built image standalone, waits for the ingress health
# endpoint, and checks the auth boundary on the API.
#
# STATUS: INACTIVE until phase 4. This script is written against the
# package's FINAL runtime shape: nginx fronting the app on the manifest
# httpPort with the API reachable on that same port, and a key generated
# into a mounted /app/data on first boot, per ADR 0003, ADR 0005, and
# ADR 0006. As of phase 2 (scaffolding), neither Dockerfile (phase 3) nor
# start.sh/nginx.conf (phase 4) exist yet, so there is no image to build
# and this script cannot pass. Do not treat a failure to run right now as
# a defect; treat it as expected until phase 4 lands. Re-read this
# comment before debugging a "failure" that happens pre-phase-4.
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
  rm -rf "$DATA_DIR" "$MODELS_DIR"
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
  -v "${DATA_DIR}:/app/data" \
  -v "${MODELS_DIR}:/var/lib/speaches" \
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

echo "=== read the generated key from the mounted data dir ==="
KEYS_ENV="${DATA_DIR}/.secrets/keys.env"
for _ in $(seq 1 30); do
  [[ -s "$KEYS_ENV" ]] && break
  sleep 1
done
if [[ ! -s "$KEYS_ENV" ]]; then
  echo "FAIL: ${KEYS_ENV} was never created" >&2
  exit 1
fi
API_KEY="$(grep -m1 '^API_KEY=' "$KEYS_ENV" | cut -d= -f2-)"
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

# TODO (phase 3/4, once the default preload model set is finalised per
# ADR 0004): add one real transcription call and one real synthesis call
# here, the same way ADR 0002 requires a runtime smoke test before any
# rig contact. Keep it to one call of each: CPU inference is a scarce
# resource during gates and smoke runs, never a retry storm.

if [[ "$fail" -ne 0 ]]; then
  echo "==================================================="
  echo "smoke test FAILED"
  exit 1
fi
echo "==================================================="
echo "smoke test OK"
