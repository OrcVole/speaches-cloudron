This app is an **API server with a playground UI**. The domain serves the
OpenAI-compatible speech API at `/v1` and a small playground UI at `/`.

**Your API key** was generated on first run. Open a Terminal for this app
(the `>_` button) and run:

```
cat /app/data/.secrets/keys.env
```

Send it as `Authorization: Bearer <key>` with every `/v1` request.

**The playground UI is open to visit but not to use.** Anyone can load `/`,
but it cannot transcribe or synthesise anything without the same key.
Paste the key into the UI's key box once; your browser remembers it after
that.

**First boot is slower than later boots.** The default speech to text and
text to speech models download and load before they can serve a request.
Watch the app's Logs for progress.

**Change the default models** by setting `SPEECH_STT_MODEL`,
`SPEECH_TTS_MODEL`, or `SPEECH_TTS_VOICE` in the app's Environment section
and restarting. Add more models to warm at boot with
`SPEECH_EXTRA_PRELOAD`.
