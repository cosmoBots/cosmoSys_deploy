# Local inference service — experimental v0.1

Independent Python 3.12 process, standard library only. The HTTP layer has no
GPU dependency; the configured Ollama server owns model execution. No models
are downloaded and no Ollama process is started automatically.

Set `AI_SERVICE_TOKEN_FILE` to a private UTF-8 file outside the repository with
a random token of at least 32 characters. Set `OLLAMA_URL` (default
http://127.0.0.1:11434) and `OLLAMA_MODEL` (default qwen3:8b).
Run `python services/inference_server.py --port 3130`.

The service binds only to 127.0.0.1. All requests require
`Authorization: Bearer <token>`. Do not expose this development server to a LAN.

- `GET /health`: service liveness, not a provider/GPU readiness test.
- `POST /v1/chat`: JSON object containing `messages` (role/content pairs),
  optionally `format`, `think`, and bounded `options` (temperature, num_ctx,
  num_predict). Model selection belongs to server configuration.
- Response: Ollama-compatible JSON including `message.content`.
- Errors: 401 authentication, 404 route, 413 size/framing, 415 media type,
  422 validation, 429 busy, 502 provider failure (details redacted).

Example body:
```json
{"messages":[{"role":"user","content":"Resume este texto de prueba."}],"think":false}
```

Requests are synchronous, with one inference at a time and a 200 KB body cap.
There is no persistent job queue, cancellation, transcription endpoint or
publication endpoint yet. The existing desktop apps have not been switched.

Validation: `python -m unittest discover -s services -v` (7 tests passing,
including real loopback HTTP with a fake provider). Real model inference and
packaging on a clean machine remain unverified for this service.

## Contributions

Development target: `fpgulias/cosmoSys_deploy`, branch
`development/standalone-services`. Contributors can fork this repository,
commit their changes and open a PR with that repository/branch as the base.
This is independent of draft PR #13 in cosmoBots. Preserve attribution and
license notices; do not commit private tokens, recordings or models.
