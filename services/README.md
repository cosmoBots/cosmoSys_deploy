# Local inference service — experimental v0.1

## Transcription service

`python services/transcription_server.py --port 3133` exposes authenticated
`POST /v1/transcriptions` with a raw `application/octet-stream` audio body.
Set `TRANSCRIPTION_TOKEN_FILE` (32+ characters) and `WHISPER_CACHE` to the
pre-downloaded model cache. The service needs faster-whisper and its runtime
dependencies; the desktop REST client does not. Device/model/index/precision
are configured with the existing WHISPER_* variables. CPU and alternative GPUs
are configurable, not all tested. No automatic downloads occur.

Responses contain segments with start/end seconds and text, language `es`,
and review_required=true. Audio is limited to 50 MB, processed serially and
stored temporarily, then deleted on normal completion/error. Process crashes
may leave temporary files. There is no duration limit, queue or cancellation;
compressed long audio can occupy the worker for a long time. The loaded model
stays resident until the process stops. Health does not load the model.

Add TRANSCRIPTION_TOKEN_FILE and WHISPER_CACHE to the launcher's private
environment. With AUTHORING_SERVICES=1 the installed actas/dictado client sends
audio to this service (TRANSCRIPTION_URL defaults to loopback port 3133).

Validated on 2026-10-23 with installed client, running HTTP service and real
Whisper/CUDA: synthetic spoken Spanish was returned as two matching phrases
with timestamps. 17 service tests passed and the expanded OpenAPI validated.
Real microphone workflows and alternative CPU/GPU configurations are separate
checks. No production content was published.

The machine-readable API contract is `services/openapi.json` (OpenAPI 3.1).
Each operation specifies its service port. Supply that service's bearer token.
This contract can be imported into API clients or rendered by an OpenAPI viewer;
it does not expose credentials or start an HTTP documentation server.

## Local launcher

`python services/start_local.py /private/launcher.json --app actas` starts the
three authenticated loopback services and opens the configured desktop app.
Use `--app dictado` for dictation, or omit it to start services only.
The private JSON has `environment` (the token/config path variables below),
`client_python` (Python executable) and `client_directory` (desktop client folder).
Set Redmine project-list credentials in that environment as well.
Keep this file and all secrets outside Git and restrict OS access to the user.
The launcher reuses authenticated healthy services; it does not install a
Windows service, auto-start at login, or restart running services after updates.
Close/restart the processes deliberately when changing configuration/code.

## Real Redmine integration validation

On 2026-10-23, `validate_redmine.py` passed against the disposable
semantic-isolated Redmine instance (real Rails/Redmine and PostgreSQL, synthetic
private project). Checked: preview does not create a wiki page, exact Unicode
and multiline text preservation, retry reuses the page without a new revision,
changed content with the same identity is rejected without mutation, and a
read-only account can read but cannot create a page. Synthetic pages remain in
the disposable database for inspection. No production project was modified.

Run only on a disposable instance:
`python services/validate_redmine.py URL PROJECT PRIVATE_KEYS_JSON`.
The private JSON contains `editor` and `reader` API keys and must stay outside
the checkout. Provision the writer and read-only member separately. This test
exercises Publisher and the real REST adapter; HTTP publication ingress is
covered separately by the unit suite. Multi-process races, production rollout
and GUI integration are not covered by this check.

## Desktop integration

The versioned `clients/IA-local/actas.py` and `dictado.py` support
`AUTHORING_SERVICES=1`. Set the service token files described below and start
the three services before launching the desktop client. `MINUTES_URL` and
`PUBLICATION_URL` default to loopback ports 3131 and 3132.
Acta generation goes through minutes REST; reviewed acta/dictation publication
goes through publication REST. Project listing still uses the existing Redmine
read adapter; audio transcription still calls local Whisper directly.
Without this explicit switch the previous desktop implementation remains active.
No files in an existing installed copy are automatically replaced.

On 2026-10-23, `python services/smoke_local_model.py` passed using real local
Ollama qwen3:8b through both HTTP services and the desktop service client.
Publication used an in-memory destination and verified retry behavior. No real
Redmine write was performed: permissions, formatting and remote conflicts still
need a dedicated disposable Redmine integration test. Unit suites: 16 service
tests plus 5 desktop dictation/client tests passed. The synthetic smoke test is
explicit and not part of ordinary CI, which must not depend on a GPU/model.

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

## Meeting minutes service

Run `python services/minutes_server.py --port 3131` in another process.
`MINUTES_SERVICE_TOKEN_FILE` contains its own private token (32+ characters);
`AI_SERVICE_TOKEN_FILE` contains the inference service token.
`INFERENCE_URL` defaults to http://127.0.0.1:3130. Both services bind to loopback.

Authenticated `POST /v1/minutes/draft`, Content-Type application/json:
```json
{"transcript":"Revisamos el proyecto. Ana enviará el informe mañana."}
```
Returns `status: draft`, `review_required: true`, `text` (Markdown), and
`transcript_sha256` binding the output to the exact input. Maximum input:
42,000 characters and 200 KB request body. No silent truncation.
The service checks supporting quotations against the transcript but cannot
prove that the model's interpretation is correct: human review is required.
No publication route, Redmine credentials, GPU imports or local model launcher
are present in this service. It calls inference through `RemoteInference`.

Errors: 401 authentication, 404 route, 413 body size, 415 media type,
422 invalid transcript, 429 busy, 502 rejected model output/provider failure.
It is synchronous and stateless; no persistence, cancellation or retry queue.
`GET /health` is authenticated liveness only.

The services test suite now has 11 passing tests, including two live loopback
HTTP servers connected through the adapter with simulated inference. This does
not validate real-model quality or production deployment. Existing desktop apps
still use their previous implementation.

Validation: `python -m unittest discover -s services -v` (7 tests passing,
including real loopback HTTP with a fake provider). Real model inference and
packaging on a clean machine remain unverified for this service.

## Contributions

## Publication service (experimental)

Run `python services/publication_server.py --port 3132` with
`PUBLICATION_TOKEN_FILE` (private bearer token, 32+ characters) and
`PUBLICATION_CONFIG_FILE` (private JSON outside the repository). Example config:

```json
{"cosmosys":{"adapter":"redmine-wiki","url":"http://localhost:3080","api_key_file":"/private/redmine-key","projects":["demo"]}}
```

Add a `cgrol` destination with its URL, credential file and permitted projects
to use the same Redmine adapter there. Other applications need their own adapter;
arbitrary destination URLs are not accepted in requests. Use HTTPS for remote
backends. The local API binds to loopback and requires bearer authentication.

1. POST `/v1/publications/preview` with `destination`, `project`, `text` and
   `request_id` (all strings). Returns exact text, target wiki page,
   `content_sha256` and a `review_token` valid for 30 minutes. No remote writes.
2. Review the returned text and target.
3. POST `/v1/publications/commit` with that token, hash and `confirmed: true`.

The adapter publishes the exact supplied Redmine wiki source. Clients must
escape/format untrusted material appropriately before review. Do not submit
raw model output automatically. A bearer client can assert confirmation;
the service cannot prove that a human actually reviewed the text.

Page identity derives from destination/project/request_id. Retries with the
same identity and content reuse the existing page; different content conflicts.
After restart, preview again with the same request_id. Reviews are memory-only.
The server serializes local commits; Redmine GET-then-PUT is not a distributed
atomic create. Run one publisher and reserve the Publication_ page namespace:
concurrent external writers can race. This is not an exactly-once delivery guarantee.
It creates wiki pages only, not issues, semantic entities or academic references.
No real destination has been modified during validation.

Tests: 16 passing across services, including authenticated publication HTTP
with a fake destination. Real Redmine permissions/network behavior and
end-to-end UI integration still need separate validation.

## Contribution destination

Development target: `fpgulias/cosmoSys_deploy`, branch
`development/standalone-services`. Contributors can fork this repository,
commit their changes and open a PR with that repository/branch as the base.
This is independent of draft PR #13 in cosmoBots. Preserve attribution and
license notices; do not commit private tokens, recordings or models.
