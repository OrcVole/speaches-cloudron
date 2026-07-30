<!--
This file IS tracked and IS published. It is the ANONYMISED verified-versus-
assumed log. Box-specific detail (real FQDNs, sibling app names, the private
mirror, session specifics) belongs in gitignored phase-notes/, never here.
Newest entry first. Each entry is dated and says what was PROVEN, not what
was expected.
-->

# Packaging notes (verified-versus-assumed log, newest first)

Anonymised. Box-specific detail lives in the maintainer's local notes, not here.

---

## 2026-07-30: Phase 0 recon, verified versus assumed

Before any packaging work began, a recon pass checked whether a Cloudron
package for Speaches already existed, confirmed the licence and upstream
release state, and probed the pinned upstream CPU image directly on a
local workstation, with no target host contact. The full recon record is
kept locally; this entry is the anonymised, publishable summary of what
recon actually proved versus what it merely expected.

**Validated (decisions that held up):**

- **No existing package.** Checked exhaustively across the community app
  store, the packaging forum, the full project index, and GitHub. No
  Speaches package, and no comparable OpenAI-compatible STT/TTS package,
  exists anywhere on the platform, and forum threads show active unmet
  demand for a local Whisper-class backend.
- **Licence.** MIT, confirmed by reading the upstream repository's LICENSE
  file directly, not by inference from a badge or a package index.
- **Install method.** There is no PyPI package for the server itself, only
  a thin CLI stub; the upstream Dockerfile installs with `uv sync
  --frozen` against the repository's own lock file. This settled the
  build-shape question in favour of reproducing that install on the
  packaging base image rather than copying a virtual environment across
  images.
- **Fast, simple boot.** Unlike a large-model inference server, the
  pinned image reaches a healthy port bind within a few seconds with an
  empty model cache, because models load on demand rather than at process
  start. This removed the need for an immediate-health proxy shim for the
  general case.
- **Auth exists and is real.** The unprefixed `API_KEY` environment
  variable gates the `/v1` and `/api` surfaces with a bearer token, tested
  directly against the pinned image with a correct key, a wrong key, and
  no key.
- **CPU inference works end to end.** A real model download followed by a
  real transcription succeeded on CPU on a local workstation. This proves
  the mechanism, not the target host's performance envelope: the
  workstation used for this test has a wider CPU instruction set than the
  eventual target host, so throughput numbers from it are not treated as
  representative and are not published anywhere.

**Surfaced (things that were wrong or missing, and are now fixed):**

- **The authentication topology draft was wrong on first pass.** The
  initial assumption was that an openly reachable playground UI meant
  open, unauthenticated inference, which would have justified an
  SSO-style wall in front of the whole app. Reading the upstream source
  directly, its auth dependency and its UI code, showed the UI ships its
  own key entry box and cannot run inference without it: the openly
  reachable surface is a harmless shell, not an open service. The
  decision record was corrected in place, with the earlier reasoning kept
  rather than deleted, so the correction is visible rather than silent.
- **The unprefixed environment variable naming was not obvious in
  advance.** An early assumption that the upstream project might reserve
  its own name as an environment variable prefix turned out to be false:
  upstream reads generic, unprefixed names such as `API_KEY` and `PORT`
  directly from its own configuration model. Package-only settings were
  given their own distinct prefix specifically so that they can never
  collide with a name upstream might introduce later.

**Still open:**

- Whether the target host's CPU instruction set supports the inference
  library at real, measurable throughput. Proven only on wider-instruction
  hardware so far; the honest number is deferred until it can be measured
  on the actual target.
- The exact default model set to preload at boot, balanced against target
  host memory and startup time, is not yet fixed.
- Several environment variable and authentication behaviours were read
  from upstream source rather than observed on a running instance, and
  still need an empirical proof pass once a built image exists.

---

## Conventions for this file

- Newest first, so the top of the file is always the current state of
  knowledge.
- Every claim carries its evidence. "It works" is not an entry; "a 4 MiB
  upload returned 200 and the downloaded bytes were sha256-identical" is.
- Distinguish verified from assumed explicitly. An assumption written as a
  fact is the single most expensive thing this document can contain.
- Anything that generalises beyond this application gets harvested into
  the private field guide at the end of the round. This file is the
  application's record; the field guide is the doctrine.
- Gate ladder evidence tables live in `docs/DEBUGGING.md` or the relevant
  ADR. This file records what the gates taught, not the raw runs.
