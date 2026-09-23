[0.1.1]

- Security update. Two CRITICAL and about thirty HIGH vulnerabilities in the bundled Python
  packages are fixed, including anyio and h11 (CRITICAL), starlette, pillow, cryptography, urllib3,
  python-multipart, gradio and protobuf. Speaches itself is unchanged (still 0.9.0-rc.3): the
  dependency set is upstream's own, re-resolved within speaches' own version constraints. No fixable
  HIGH or CRITICAL issue remains in the app's own packages; what a scanner still reports comes from
  the Cloudron base image.
- The web playground moves to Gradio 6. Two small source fixes keep it working: the audio chat tab,
  and the script that remembers your API key in the browser.
- Base image cloudron/base 5.0.0 to 5.1.0: the Ubuntu 24.04.4 point release, with its OS security
  updates.

[0.1.0]

- Initial package of Speaches, upstream version 0.9.0-rc.3, CPU inference
  only.
- Speech to text (faster-whisper), text to speech (Kokoro, Piper), and the
  realtime WebSocket API, fronted by an OpenAI-compatible HTTP API.
