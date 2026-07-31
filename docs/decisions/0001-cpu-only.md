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

## Measured on the rig, 2026-07-31 (Gate 2)

The single most important CPU finding of the round, and it was invisible
locally. Upstream's default `compute_type` resolves to float32 on CPU. With
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

