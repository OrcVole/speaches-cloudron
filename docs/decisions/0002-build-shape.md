# ADR 0002: build shape

Status: proposed with an open fork (architect skeleton, 2026-07-30; executor
resolves the fork at phase 3 with a build gate and runtime smoke). Adopted
into repo at phase 2; operator-approved where marked.

## Context

The final stage must be cloudron/base pinned by digest (compliance rule; the
dashboard tooling depends on its userland). cloudron/base:5.0.0
(sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c) is
Ubuntu 24.04 with Python 3.12.3. The upstream CPU image
(ghcr.io/speaches-ai/speaches:0.9.0-rc.3-cpu, digest
sha256:2163775b6df5e451a71200e8f675fed68dbd8ab184fc604453d549e486f22fd2) is
also Ubuntu 24.04, with the app venv at /home/ubuntu/speaches/.venv on
Python 3.12.11. Same distribution, same glibc generation, same Python minor.

Resolved by upstream recon (phase-notes/upstream-recon.md): no PyPI server
package exists (only a speaches-cli stub). The upstream Dockerfile is a
single stage that copies the uv 0.10 binary from the astral image and runs
uv sync --frozen --compile-bytecode --no-dev against the repo's uv.lock;
python is pinned ==3.12.* (uv downloads it, though base already has
3.12.3); runtime apt deps are exactly ca-certificates curl ffmpeg (ffmpeg
required for mp3 and other formats); pyproject deliberately
force-overrides onnxruntime-gpu on x86_64 (CPU EPs work; keep the lock's
choice rather than "fixing" it, so we ship what upstream tests).

Two candidate shapes, in order of current preference:

1. Fresh venv on cloudron/base: builder stage clones the repo at tag
   v0.9.0-rc.3 (pinned commit), installs the pinned uv 0.10 binary by URL
   and SHA256, runs uv sync --frozen against the shipped uv.lock (which
   reproduces upstream's exact dependency set, including the deliberate
   onnxruntime-gpu override), then the runtime stage copies the venv and
   src tree. Doctrine default (field guide 4.2, digest 1.2) and now known
   to be exactly what upstream's own image does, minus their base.
2. Venv-copy: builder stage FROM the official upstream cpu image by digest,
   COPY the venv and app directory into cloudron/base, patch shebangs and
   paths. Byte-identical to what upstream tests; doctrine calls cross-image
   venv copies brittle in general (digest 1.2), but this is the same-distro
   same-python case, and the probe already proved the stack works.

## Decision (proposed)

Attempt shape 1 first with a hard timebox of one build cycle plus one fix
attempt; on failure or on a dependency set that diverges from upstream
meaningfully, fall back to shape 2. Either way: two-stage build, builder
holds all download caches, runtime stage copies only the venv and app tree
(digest 1.3); exactly one build ARG for the upstream version mirrored into
manifest upstreamVersion; every downloaded artefact pinned; CMD not
ENTRYPOINT.

## Consequences

- Shape 2 keeps us aligned with the exact artefact upstream publishes and
  tests, at the cost of provenance elegance; shape 1 the reverse. Both end
  on cloudron/base as the final stage.
- The build gate proves imports and linkage only; the real gate is a runtime
  transcription and a TTS call (digest 1.7).

## Executor verification hooks

- [ ] Confirm upstream install method and PyPI status from recon report.
- [ ] ldd-derive the runtime apt set empirically (ffmpeg presence [verify]:
      transcoding of non-wav uploads likely needs it; check upstream image
      for ffmpeg and copy the conclusion, not the assumption).
- [ ] Build gate: import speaches, ctranslate2, onnxruntime; assert
      onnxruntime CPU providers available.
- [ ] Runtime smoke: real STT call and real TTS call inside the built image
      before any rig contact.
