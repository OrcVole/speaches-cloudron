# Speaches for Cloudron

[Speaches](https://github.com/speaches-ai/speaches) packaged as a Cloudron
app. Speaches is a self-hosted speech server with an OpenAI-compatible
API: speech to text (faster-whisper), text to speech (Kokoro and Piper
voices), and a realtime API over WebSocket. See DESCRIPTION.md for the
full description shown in the Cloudron App Store, including an honest note
on the upstream project's current pace of development.

## Quick start

1. Install the app from the Cloudron App Store (or from this repository's
   `CloudronVersions.json`, once published).
2. Open a Terminal for the app (the `>_` button in the dashboard) and read
   the generated API key:

   ```
   cat /app/data/.secrets/keys.env
   ```

3. Call the API with the key as a bearer token. Example transcription
   request, with `example.com` standing in for the app's real domain:

   ```
   curl https://example.com/v1/audio/transcriptions \
     -H "Authorization: Bearer <key>" \
     -F file=@sample.wav \
     -F model=Systran/faster-whisper-small
   ```

4. Alternatively, open the app's domain in a browser to use the playground
   UI, and paste the same key into its key box once per browser.

### Wiring into OpenWebUI

In OpenWebUI, set Admin Settings, Audio, Speech to Text Engine to OpenAI,
with the base URL `https://example.com/v1` and the key from `keys.env`.
Set the Text to Speech Engine the same way, choosing a voice that matches
one of the TTS models this package preloads (see `SPEECH_TTS_VOICE`
below).

### Wiring into LibreChat

LibreChat's `librechat.yaml` speech configuration takes full endpoint
URLs, not a base URL. Point transcription and synthesis at:

```
https://example.com/v1/audio/transcriptions
https://example.com/v1/audio/speech
```

Some LibreChat documentation examples show `/v1/audio/synthesize` for the
speech endpoint. That path does not exist on Speaches, or on OpenAI, and
is a documentation error. Use `/v1/audio/speech`.

## Settings

| Setting | Purpose |
|---|---|
| `SPEECH_STT_MODEL` | Default speech to text model, preloaded at boot. |
| `SPEECH_TTS_MODEL` | Default text to speech model, preloaded at boot. |
| `SPEECH_TTS_VOICE` | Default voice for the preloaded text to speech model. |
| `SPEECH_EXTRA_PRELOAD` | Comma-separated list of additional model IDs to warm at boot, appended to the defaults. |
| `SPEECH_COMPUTE_TYPE` | `int8` | CTranslate2 quantisation for speech to text. `int8` is four times faster and six times smaller than `float32` on CPU, measured on real hardware. Raise it only if accuracy demands it and the memory limit allows. |
| `SPEECH_UI` | Set to `off` to disable the playground UI and expose the API only. Defaults to on. |
| `HF_TOKEN` | Passed straight through to Hugging Face Hub, unmodified, for gated models. Unset by default. |

Package settings use the `SPEECH_` prefix so that they can never collide
with an upstream Speaches configuration field. See
`docs/decisions/0006-env-namespace.md` for the reasoning.

## Persistence and backup

Model weights are cached under `/var/lib/speaches`, on a persistent volume
that is deliberately excluded from the app's backups: the cache is large,
churns during downloads, and is fully reproducible from Hugging Face. If
this app is restored onto a fresh volume or cloned, the cache starts empty
and the preloaded models download again on first boot. Everything else,
including the generated API key, lives under `/app/data` and is backed up
normally.

## Design decisions

The architecture decisions behind this package, including why it runs on
CPU only, how the image is built, why nginx sits in front of the app, how
the model cache is handled, the authentication topology, and the
environment variable namespace, are recorded as ADRs in
`docs/decisions/`. Platform-level findings offered back to the Cloudron
team live in `docs/FOR-CLOUDRON.md`; findings offered back to Speaches
upstream live in `docs/FOR-UPSTREAM.md`.

## Performance

This package runs Speaches on CPU only, because Cloudron does not offer
GPU passthrough. Any specific throughput numbers, such as audio seconds
transcribed per second or time to first audio for speech synthesis, are
measured on the real target hardware before being published here, rather
than estimated or copied from unrelated hardware. Until that measurement
is recorded, treat CPU performance as workable for short and medium audio
with small models, and slow for long files or large models.

## Licence

Speaches is MIT licensed; see LICENSE. This packaging is offered under the
same terms.
