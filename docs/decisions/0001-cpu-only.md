# ADR 0001: CPU-only inference for the first release

Status: proposed (architect skeleton, 2026-07-30; executor confirms at phase 3). Adopted into repo at phase 2; operator-approved where marked.

## Context

Cloudron offers no GPU or device passthrough for apps; the platform precedent
(official Ollama package, our vLLM package) is CPU-only for exactly this
reason. Upstream ships every release in matched cpu and cuda image variants
(and cuda-12.4.1 variants from 0.7.0 on), so a CUDA sibling image remains
possible later without re-architecting. The Cloudron-GPU-CDI track, if it
lands, is the trigger to revisit.

The CPU stack is proven in the upstream image: faster-whisper on CTranslate2
4.5.0 for STT, Kokoro (kokoro_onnx) and Piper (piper_tts) on onnxruntime for
TTS. A local workstation probe of 0.9.0-rc.3-cpu completed a real
transcription end to end on CPU. The target host is AVX2-class; CTranslate2
publishes AVX2 support, and the probe host (AVX-512) does not prove the AVX2
envelope. Honest throughput numbers come from Gate 4 on the target, never
from documentation or a different machine.

## Decision (proposed)

Package the upstream CPU variant only. State the performance reality plainly
in every user-facing text once measured. Do not carry dormant CUDA weight.
Structure nothing in a way that would block a parallel CUDA image variant
later.

## Consequences

- Transcription speed on CPU is workable for short and medium audio with
  small and distil models; long files and large models are documented as
  slow rather than promised fast.
- The measurement discipline from the vLLM round applies: measure tokens or
  audio-seconds per second on the target host at Gate 4, then write that
  number into README and the announcement.

## Executor verification hooks

- [ ] Confirm CTranslate2 runs on the target host CPU (AVX2) with a real
      transcription during Gate 2; a build-time import gate cannot prove
      this (field guide gotcha 1 generalised; digest item 10.4).
- [ ] Record audio-seconds-per-second for the default STT model and first
      token latency for TTS at Gate 4.

## Quantisation, measured properly (2026-07-31)

Upstream's `compute_type` resolves to float32 on CPU. The package overrides
this, selecting from the CPU's own feature flags at boot.

The first evidence for that change was taken on the rig and claimed a
fourfold speed-up. THAT CLAIM IS RETRACTED: the rig was carrying a load
average of 51.5 on 12 cores with neighbouring containers taking 412 and 349
percent CPU, so those timings measured the neighbours rather than the
package.

Re-measured under control, on a quiet machine (load 1.5 to 2.4 on 32 cores),
with the two quantisations running in otherwise identical containers and
requests INTERLEAVED between them so that any shared load affects both arms
equally. Timings are the application's own, excluding model load:

| Quantisation | Run 1 (cold) | Run 2 | Run 3 |
| --- | --- | --- | --- |
| int8 | 1.75 s | 1.01 s | 1.00 s |
| float32 | 2.52 s | 1.49 s | 1.44 s |

int8 is roughly 1.4 times faster, consistently and in both the cold and warm
cases, for the same 4.9 second clip. That is a real and reproducible
advantage, and much smaller than first reported. It is kept as the default
because it is faster, because it uses materially less memory for the same
weights, and because there was no accuracy difference on the test phrase.

Absolute throughput on that quiet machine was roughly three to five times
FASTER than real time, which is worth stating plainly because the rig
figures suggested the opposite. The package is not slow; the rig it was
first measured on was saturated.

Honest framing for user-facing text: performance depends overwhelmingly on
how busy the host is and on its instruction set. No throughput promise
should be made for a shared server. See `docs/DEBUGGING.md`.

## Superseded rig measurement, kept for the record (2026-07-31)

RETRACTED as a causal claim, kept because the retraction is instructive.
These figures were taken on a saturated rig without recording its load, and
the fourfold difference they appear to show is not reproducible under
control. Upstream's default `compute_type` resolves to float32 on CPU. With
that default, `faster-whisper-small` transcribed 4.9 seconds of audio in 199
to 236 seconds and drove the container to 4.07 GB, which is 94.8 percent of
a 4 GiB limit. Switching CTranslate2 to int8, same audio, same model, same
hardware: 49 to 59 seconds and 671 MB. Four times faster, six times smaller,
with no accuracy difference on the test phrase.

`start.sh` therefore selects quantisation from the CPU's own flags rather
than hardcoding it, because the right choice depends on the silicon: int8
wherever AVX2 or better is present (and especially where VNNI int8 dot
product instructions exist), int8_float32 on SSE 4.1 only silicon where
int8 kernels are poorly served, and a loud warning below CTranslate2's
SSE 4.1 floor. `SPEECH_COMPUTE_TYPE` overrides the detection.

Honest performance framing for user-facing text: even after the fix, this
rig (AVX2, no AVX-512, 12 cores allotted) transcribes at roughly ten times
slower than real time with `faster-whisper-small`. That is usable for short
clips and batch work, and it is not real-time dictation. Say so plainly.
Operators wanting speed should choose a smaller or distilled model.
