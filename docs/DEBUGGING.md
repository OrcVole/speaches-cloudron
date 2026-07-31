# DEBUGGING: gate evidence

Every row here is evidence, meaning a log line, a hash, a counter or a
timing, never an inference. The ladder runs against one image digest; if the
image is rebuilt the ladder restarts at Gate 0, because gates passed by a
different digest prove nothing about this one.

## Ladder restart, 2026-07-31

The gates below first ran against package revision
`0.9.0-rc.3-1`. Gate 2 failed on performance, the fix changed `start.sh`,
and the image was rebuilt as `0.9.0-rc.3-2`. The ladder therefore restarted
at Gate 0 against the new revision. The revision 1 evidence is kept because
the failure it records is the most useful thing the round produced.

## Summary

| Gate | Status | Evidence |
| --- | --- | --- |
| 0 install and first run | PASS on rev 1, rerunning on rev 2 | restart count 0, health 200, key 0600, cache on persistentDir |
| 1 auth | PASS on rev 1, rerunning on rev 2 | per-route matrix below, zero redirects for API clients |
| 2 functional flows | FAIL on rev 1, fixed, rerunning on rev 2 | transcription 40x slower than real time; root cause and fix below |
| 3 update and restore | partially observed | pre-update key hash and cache size captured below |
| 4 memory | not yet measured on rev 2 | rev 1 figures are invalid: they measured a thrashing container |

## Gate 0, install and first run (revision 1)

| Invariant | Proof |
| --- | --- |
| Installs without operator intervention | `cloudron install --image ... --location speaches-test` completed, "App is installed." |
| No restart loop | `docker inspect --format {{.RestartCount}}` returned `0` |
| Liveness answers immediately | `/healthz` 200 while models were still downloading |
| Readiness is separate and honest | `/ready` 502 during preload, 200 at 40 seconds |
| API key generated once, correct mode | `stat` reported `mode=600 owner=cloudron:cloudron size=603` |
| Model cache lands on the persistentDir | `du -sh /var/lib/speaches` returned `1.6G`, containing `hf` |
| Threads bound to the cgroup, not the host | boot log `threads : 12 (omp/mkl)` on a host with far more cores |
| No OOM | `memory.events` `oom_kill 0` |

## Gate 1, auth (revision 1)

Matrix is no key / wrong key / correct key, requested through the platform
proxy rather than against the container.

| Route | Result | Intent |
| --- | --- | --- |
| `/healthz` | 200 / 200 / 200 | platform health probe, must never require auth |
| `/ready` | 200 / 200 / 200 | readiness, deliberately open |
| `/` | 200 / 200 / 200 | Gradio UI shell, inert without a key |
| `/openapi.json` | 200 / 200 / 200 | upstream exempts it deliberately |
| `/v1/models` | 403 / 403 / 200 | keyed API |
| `/v1/audio/voices` | 403 / 403 / 200 | keyed API |
| `/api/ps` | 403 / 403 / 200 | keyed API |

| Invariant | Proof |
| --- | --- |
| No login redirect for programmatic clients | `num_redirects: 0`, final URL unchanged, with a valid key |
| Wrong key is refused, not ignored | 403 on every `/v1` route with `Bearer wrongkey` |

## Gate 2, functional flows (revision 1: FAIL, then fixed)

| Invariant | Proof |
| --- | --- |
| Text to speech returns real audio | `POST /v1/audio/speech` 200, 235598 bytes, `RIFF ... WAVE audio` |
| Speech to text returns correct text | round trip returned "The quick brown fox jumps over the lazy dog. Packaging speech for Cloudren works." |
| Both flows work through nginx and the platform proxy | all calls made to the public domain |
| Transcription is fast enough to be usable | **FAILED**: app log `Transcribed 4.9 seconds of audio in 199.8 seconds` |

### Root cause and fix

Upstream's `compute_type` default resolves to float32 on CPU. Measured on
the rig, identical audio, model and hardware:

| Quantisation | Transcribe 4.9 s of audio | Peak memory |
| --- | --- | --- |
| float32 (upstream default) | 199 to 236 s | 4.07 GB, 94.8 percent of a 4 GiB limit |
| int8 (package default from rev 2) | 49 to 59 s | 671 MB |

Four times faster and six times smaller. The memory figure explains the
timing: a container sitting at 95 percent of its limit does not necessarily
get OOM killed, it thrashes, so a performance symptom was really a memory
problem. `start.sh` now selects quantisation from the CPU feature flags at
boot; see `docs/decisions/0001-cpu-only.md`.

Recipe to repeat: generate speech with `POST /v1/audio/speech`, feed the
result to `POST /v1/audio/transcriptions`, and read the application's own
`Transcribed N seconds of audio in M seconds` log line rather than timing
the HTTP request, which also includes model load.

## Gate 3, update and restore (in progress)

Pre-update state captured on revision 1, to be compared after the update to
revision 2:

| Invariant | Pre-update value |
| --- | --- |
| API key must survive byte identical | sha256 prefix `fc4ad461d357f2dd35fc26e2510c515b` |
| Model cache must survive an update | 1677310530 bytes on `/var/lib/speaches` |

## Gate 2 rerun, revision 2 (PASS)

Identical audio, model and hardware as the revision 1 failure. Timings are
the application's own log line, not the HTTP request, so model load is
excluded.

| Run | Transcribe 4.9 s of audio |
| --- | --- |
| first after load | 60.4 s |
| steady state | 47.9 s |
| steady state | 45.0 s |

Against 199 to 236 s on revision 1: roughly four times faster, from the
quantisation change alone. Text to speech returned 129102 bytes of wav in
15.8 s for a short phrase.

Honest framing for user-facing text: on this rig (AVX2, no AVX-512, 12
cores allotted) `faster-whisper-small` transcribes at roughly nine to ten
times slower than real time. That is useful for short clips and batch work
and is not real-time dictation.

## Gate 4, memory (revision 2)

Measured with the full default model set resident (`faster-whisper-small`,
Kokoro and the Silero VAD) immediately after real inference in both
directions.

| Invariant | Idle after boot | Loaded, after inference |
| --- | --- | --- |
| `memory.current` | 356 MB (rev 1, preload only) | 1443758080 bytes, 1.34 GiB |
| `memory.peak` | n/a | 1463017472 bytes, 1.36 GiB |
| `oom_kill` | 0 | 0 |
| largest process | uvicorn | uvicorn, 1489996 KB RSS |

### Sizing, and a retracted explanation

`memoryLimit` was first set to 3 GiB from the peak figure, then raised to 5
GiB after the same clip appeared to take three times longer at 3 GiB. The
RAISE IS KEPT, but the explanation offered for it has been RETRACTED, and
the retraction matters more than the number.

What was claimed: that a tight cgroup evicted the model files from page
cache, so every inference re-read weights from disk.

Why that is not supported: a later run at the 5 GiB limit, with memory
peaking at 2814689280 bytes (2.62 GiB, only 52 percent of the limit and
therefore under no pressure at all) was ALSO slow, at 153 to 207 seconds.
If memory pressure were the cause, that run would have been fast.

The confound, which should have been controlled from the first measurement:
the rig carries 84 containers and its load average was 51.5 on 12 cores,
with individual neighbours consuming 412 and 349 percent CPU. Every
wall-clock timing taken on this rig is therefore a measurement of whatever
else was running at that moment, not of this package. The apparent
differences between 45, 128 and 153 second runs are within the noise that
load of that magnitude produces.

| Counter at the 5 GiB limit | Value |
| --- | --- |
| `anon` | 839847936 (0.78 GiB), the process itself |
| `file` | 1690976256 (1.57 GiB), page cache holding model files |
| `memory.current` | 2597695488 (2.42 GiB) |
| `memory.peak` | 2814689280 (2.62 GiB), 52 percent of the limit |
| `oom_kill` | 0 |

What survives, and why 5 GiB is still the right number: the page cache
figure is a measured fact independent of timing. The cgroup is charged
about 1.6 GiB of page cache for the model files on top of roughly 0.8 GiB
of process memory, giving a real working set near 2.6 GiB. Sizing from
`memory.peak` alone, or from process RSS alone, would have missed the
larger half of that. 5 GiB puts the measured peak at 52 percent.

Rules that survive the retraction:

1. Size a model server from `anon` plus `file` in `memory.stat`, not from
   `memory.peak` alone and not from RSS alone.
2. An `oom_kill` counter of 0 is not evidence that a memory limit is
   adequate.
3. NEVER quote a wall-clock performance number from a shared rig without
   recording the load average alongside it. This round produced three
   contradictory timings for identical work and briefly believed each one.

## Outstanding: performance must be re-measured

No trustworthy throughput figure for this package exists yet. The
int8-versus-float32 comparison that drove the quantisation change was also
taken under uncontrolled load, so its DIRECTION is credible (the gap was
roughly fourfold and consistent) but its MAGNITUDE is not established.

To do properly: interleave int8 and float32 requests against two otherwise
identical containers so that load affects both equally, or measure at a
quiet period, recording `uptime` alongside every timing. Until then, no
performance claim should appear in any user-facing text.
