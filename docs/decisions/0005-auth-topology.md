# ADR 0005: auth topology

Status: ACCEPTED by the operator 2026-07-30 (option A': generated API key,
UI enabled, no proxyAuth). Drafted and revised the same evening after
upstream source reading, see history note at the bottom. Sibling
consumability is the operator's first-class requirement. Adopted into repo
at phase 2; operator-approved where marked.

## Context (empirical probe plus upstream source, 0.9.0-rc.3)

- Native auth exists: unprefixed API_KEY env; Authorization: Bearer; 403
  with WWW-Authenticate on /v1/*and /api/* without or with a wrong key.
- The auth exemptions are documented and intentional upstream: /health,
  /docs, /openapi.json, and the Gradio UI shell. The UI carries its own
  API-key textbox (persisted in browser localStorage): inference through
  the UI requires the key too. An open UI shell is therefore NOT an open
  transcription service; the openly reachable surface is benign (a form
  that cannot run anything without the key, API docs, liveness).
- The websocket realtime endpoint handles auth itself and accepts the key
  as ?api_key=, Authorization: Bearer, or X-API-Key. rc3 PR 595 revised
  this; keyless rejection must be verified empirically.
- Cloudron facts if a wall were wanted: proxyAuth is prefix-scoped, cannot
  be added after first install, and supportsBearerAuth forwards any
  Bearer-carrying request unchecked (doctrine digest section 4).

## Options

A'. Upstream posture, packaged honestly (RECOMMENDED): API_KEY generated
    first-run by the package, UI enabled, no proxyAuth, optionalSso true.
    Humans open the UI, paste the key once (POSTINSTALL and the checklist
    say exactly where to read it), the browser remembers it. Machines send
    Bearer. Identical consumer shape to vllm-cloudron. No SSO moving
    parts; nothing to break Gradio transports; first-class for siblings.
B.  Hardened variant: A' plus SPEECH_UI=off and an nginx landing page
    (the vLLM pattern exactly). For operators who want zero browser
    surface. Ships as a documented setting, not the default.
C.  proxyAuth on / with supportsBearerAuth plus the native key (the
    earlier draft's recommendation). Adds Cloudron SSO in front of the UI
    shell. Rejected as default now the shell is known to be inert without
    the key: the added wall buys little, risks Gradio transport breakage,
    and proxyAuth-from-day-one is a one-way manifest door. Recorded here
    so the reasoning survives; revisit only if upstream ever makes the UI
    key-free.

## Decision (proposed)

Option A'. Key generation cribs vLLM start.sh exactly: first-run openssl
rand -hex 32 into /app/data/.secrets/keys.env, 0600 inside 0700, ownership
and mode re-asserted every boot, never regenerated, exported as API_KEY,
never on argv. optionalSso true, no proxyAuth. SPEECH_UI setting maps to
ENABLE_UI for option B behaviour. POSTINSTALL and checklist carry the
key-read command, the Bearer header, the UI paste-once note, and the
open-shell explanation.

## Consequences

- Sibling apps and external clients authenticate with the one generated
  key; humans paste the same key into the UI once per browser.
- The open surface (/health, /docs, /openapi.json, UI shell, realtime
  console statics) is documented rather than hidden; anyone probing the
  domain learns what it is but can run nothing.
- No SSO integration means no Cloudron user mapping; acceptable for an
  API-first app (the vLLM precedent, ADR 0005 there).

## Executor verification hooks

- [ ] Prove the UI shell is inert keyless: attempt an STT run in the UI
      without a key on the test install; expect a 403-surfaced error.
- [ ] Prove keyless websocket /v1/realtime connects are rejected on rc3.
- [ ] Bearer path from outside: real key 200, wrong key 403, no key 403
      on /v1/models (Gate 1 matrix like the probe tables).
- [ ] SPEECH_UI=off path: UI absent, landing or 404 documented, API
      unchanged (option B smoke).
- [ ] Confirm /docs and /openapi.json exposure is acceptable to the
      operator or add an nginx block toggle.

## History

First draft recommended option C (SSO wall plus Bearer passthrough) on the
belief that the open UI meant open inference. Upstream source reading the
same evening (dependencies.py, ui/app.py: HTTPBearer with documented
exemptions, UI key textbox) corrected the premise; the recommendation
moved to A' and the change is recorded rather than silently rewritten.
