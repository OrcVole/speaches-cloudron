# Speaches Cloudron package: two-stage CPU build (ADR 0002, shape 1).
#
# Both stages pin cloudron/base:5.1.0 by digest (Ubuntu 24.04, Python
# 3.12.3). The builder clones upstream at the pinned release tag and runs
# uv sync against the shipped uv.lock, reproducing upstream's own
# dependency set exactly, including the deliberate onnxruntime-gpu
# override on x86_64 (see docs/decisions/0002-build-shape.md: CPU
# execution providers still work; keep the lock's choice rather than
# fixing it, so we ship what upstream tests). The runtime stage copies
# only the venv and the application tree; no download or build cache
# crosses the stage boundary.
#
# start.sh and nginx.conf are phase 4 (docs/decisions/0003, 0005, 0006).
# This image's CMD runs uvicorn directly so it is testable standalone:
# it therefore also runs as root and binds 0.0.0.0, both temporary and
# superseded once start.sh exists (user drop and host/port force to
# 127.0.0.1 behind nginx are start.sh's job, not this Dockerfile's).

ARG SPEACHES_VERSION=0.9.0-rc.3

FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e AS builder
ARG SPEACHES_VERSION

# uv binary, upstream's own method (docs/decisions/0002): copied from
# astral's own image rather than curl-piped. Pinned by digest resolved
# with `skopeo inspect docker://ghcr.io/astral-sh/uv:<tag>` (an OCI
# image index digest; podman/docker resolve the right per-arch manifest
# from it automatically at pull time).
#
# DEVIATION from the phase 3 brief's assumed 0.10.x: the pinned release
# tag's own pyproject.toml sets [tool.uv] required-version = "~=0.8.14"
# (confirmed by reading that exact file at commit
# 24f209c90218187747a9205f0b84bc06b42ce775, and independently by a first
# build attempt with uv 0.10.12, which failed fast with "Required uv
# version `~=0.8.14` does not match the running version `0.10.12`").
# uv enforces this constraint itself and refuses to run otherwise, so
# 0.10.x cannot build this exact pinned tag. Using the exact version
# upstream names removes any ambiguity about which 0.8.x patch is
# meant.
COPY --from=ghcr.io/astral-sh/uv:0.8.14@sha256:f3660c56d5b08d6c516360981bedc439f499b9bf37f46a216018da3777a74011 /uv /usr/local/bin/uv

# cloudron/base:5.1.0 already carries python3.12, python3.12-venv, git,
# and ca-certificates (confirmed empirically before writing this
# Dockerfile: dpkg -l shows python3.12-venv already installed, and git
# clone / uv sync both reach github.com and pypi.org over HTTPS with no
# extra packages). No apt-get step is needed in the builder. uv is
# pinned to that system interpreter rather than downloading its own.
ENV UV_PROJECT_ENVIRONMENT=/app/code/venv \
    UV_PYTHON=/usr/bin/python3.12 \
    UV_PYTHON_DOWNLOADS=never \
    UV_LINK_MODE=copy

WORKDIR /app/code

# Clone at the pinned release tag, shallow, and print the resolved
# commit so it lands in the build log (AGENTS.md golden rule 2: pin
# everything; the tag itself can be force-moved upstream, the commit
# cannot).
RUN git clone --depth 1 --branch "v${SPEACHES_VERSION}" \
      https://github.com/speaches-ai/speaches . \
    && echo "==> resolved speaches commit: $(git rev-parse HEAD)"

# uv sync installs the root project plus its full dependency closure
# from the frozen lock. model_aliases.json and realtime-console/dist
# are read by the app via paths relative to its working directory
# (Path("model_aliases.json"); StaticFiles(directory="realtime-console/
# dist")), not via the venv, so both must still be present alongside it
# at runtime in the same layout.
# Security overlay (2026-09-23): upstream's uv.lock at this tag pins anyio 4.9.0 and h11 0.14.0 (both
# CRITICAL CVEs) and fourteen packages with HIGH ones. overlay/uv.lock is upstream's lock re-resolved
# with uv 0.8.14 (`uv lock --upgrade-package ...` for exactly those packages, plus httpcore, which caps
# h11, and fastapi, which caps starlette), so every version satisfies speaches' OWN declared
# constraints; nothing is forced. It is only valid for the commit it was resolved against: bumping
# SPEACHES_VERSION without re-resolving it fails here rather than shipping a lock for other code.
# RE-RESOLVING: PyAV has removed its 14.4.0 wheels from the PyPI index (the files still exist on
# files.pythonhosted.org), so a re-lock rewrites av as sdist-only and the build then tries to compile
# it against ffmpeg and fails. Copy av's [[package]] block, wheels included, back from upstream's lock.
COPY overlay/uv.lock /tmp/uv.lock.overlay
RUN test "$(git rev-parse HEAD)" = "24f209c90218187747a9205f0b84bc06b42ce775" \
      || { echo "overlay/uv.lock was resolved for speaches 24f209c9, not $(git rev-parse HEAD): re-resolve it"; exit 1; } \
    && cp /tmp/uv.lock.overlay uv.lock

# gradio 6 source fixes. The overlay's gradio 6.15.1 is the only line with fixes for gradio's own three
# HIGH CVEs, and gradio 5 caps pillow below 12 and starlette below 1.0, which would leave thirteen
# pillow and two starlette HIGHs open too. speaches at this commit is written for gradio 5 in two places:
#   1. gr.ChatInterface(type="messages"): gradio 6 removed the argument (messages is the only format)
#      and the app factory dies with "unexpected keyword argument 'type'", taking the API down with it.
#   2. gr.Blocks(head=...): gradio 6 moved head to launch()/mount_gradio_app(), and mount_gradio_app
#      overwrites blocks.head with its own argument, so the script defining loadApiKey/saveApiKey
#      silently vanished and the playground's API key field broke. Pass it through explicitly.
# Reported upstream as https://github.com/speaches-ai/speaches/issues/678; drop this step once fixed there.
# Each edit must match exactly once or the build fails; the commit guard above pins the source.
RUN python3 - <<'PY'
from pathlib import Path
def edit(path, old, new):
    p = Path(path); s = p.read_text(); n = s.count(old)
    assert n == 1, f"{path}: expected 1 match for {old!r}, found {n}"
    p.write_text(s.replace(old, new)); print(f"patched {path}")
edit("src/speaches/ui/tabs/audio_chat.py", '            type="messages",\n', "")
edit("src/speaches/main.py",
     'app = gr.mount_gradio_app(app, create_gradio_demo(config), path="")',
     'demo = create_gradio_demo(config)\n        app = gr.mount_gradio_app(app, demo, path="", head=demo._deprecated_head)')
PY

RUN /usr/local/bin/uv sync --frozen --compile-bytecode --no-dev

# Build gate: proves imports and linkage only. The real gate is the
# runtime smoke test run against the built image, outside this
# Dockerfile (docs/decisions/0002, executor verification hooks).
RUN /app/code/venv/bin/python3 <<'PY'
import importlib.metadata as md

import ctranslate2
import faster_whisper
import kokoro_onnx
import onnxruntime
import speaches  # noqa: F401

providers = onnxruntime.get_available_providers()
assert "CPUExecutionProvider" in providers, providers

dists = ("speaches", "ctranslate2", "faster-whisper", "onnxruntime-gpu", "kokoro-onnx")
for dist in dists:
    print(f"{dist} {md.version(dist)}")
print("onnxruntime providers:", providers)
print("build gate ok")
PY

# ---------------------------------------------------------------------

FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e
ARG SPEACHES_VERSION
# Not named SPEACHES_VERSION at runtime: upstream's own config reads
# bare, unprefixed env var names (docs/decisions/0006-env-namespace.md),
# so leaving a package variable sitting in that same shape would be
# exactly the vLLM-round gotcha 85 lesson. UPSTREAM_VERSION is
# package-only and mirrors the manifest's upstreamVersion field.
ENV UPSTREAM_VERSION=${SPEACHES_VERSION}

# Read-only-friendly shape: uv's --compile-bytecode (builder stage) only
# reaches the venv's installed site-packages, not the project's own
# editable-installed ./src tree, and a plain COPY --from between stages
# does not reliably preserve source mtimes against what a stale copied
# __pycache__ entry expects either. Left unset, Python writes
# __pycache__/*.pyc under /app/code/src on first import (confirmed
# empirically: podman diff after a smoke run showed exactly this).
# PYTHONDONTWRITEBYTECODE=1 stops Python writing bytecode caches at
# all, trading a small one-time import cost (paid once per process
# start, not per request) for a container that never writes to
# /app/code.
ENV PYTHONDONTWRITEBYTECODE=1

# ffmpeg is required: upstream needs it for mp3 and other non-wav audio
# formats. ca-certificates and curl are already present on
# cloudron/base:5.1.0, named explicitly anyway for clarity and to
# survive a future base image that might drop them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY --from=builder /app/code/venv /app/code/venv
COPY --from=builder /app/code/src /app/code/src
COPY --from=builder /app/code/model_aliases.json /app/code/model_aliases.json
COPY --from=builder /app/code/realtime-console /app/code/realtime-console

COPY nginx.conf /app/code/nginx.conf
COPY start.sh /app/code/start.sh
RUN chmod 0755 /app/code/start.sh

# CMD, never ENTRYPOINT: ENTRYPOINT breaks Cloudron debug mode
# (AGENTS.md golden rule 6). start.sh seeds /app/data and the model
# cache on every boot, generates the API key idempotently, forces the
# upstream settings (including LOOPBACK_HOST_URL, without which Gradio
# derives its self-call URL from the inbound Host header and every UI
# action breaks behind the port remap), starts nginx on the public port,
# and execs uvicorn on 127.0.0.1:8001 so uvicorn is the container
# payload and SIGTERM reaches it. Host and port are not forced here:
# uvicorn's CLI honours UVICORN_HOST and UVICORN_PORT as environment
# variables (auto_envvar_prefix="UVICORN"), the same names the pydantic
# config reads, so start.sh drives both. HF_HOME is likewise left to
# start.sh, which redirects it onto the persistentDirs path.
CMD [ "/app/code/start.sh" ]
