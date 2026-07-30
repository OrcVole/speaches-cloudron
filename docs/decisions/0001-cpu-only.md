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
