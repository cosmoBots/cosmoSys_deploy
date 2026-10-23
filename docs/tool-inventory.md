# Optional tools: inventory and release status

These are review candidates, not a production release. Install into a disposable
instance first. No manuscripts, audio, database snapshots, credentials, signing
keys, downloaded models or third-party binaries are distributed.

| Tool | Location | Status |
|---|---|---|
| Story and academic web managers | `clients/Gestores` | Local-only prototype; REST backend; session/CSRF and persistence tests |
| Word/plain-text reversible exchange UI | `clients/Intercambio-textos/app.py` | Desktop Tk UI; now uses REST instead of deployment-specific SSH |
| Deterministic document codec | `clients/Intercambio-textos/bridge.py` | Six round-trip, integrity and edit tests |
| Exchange and typed semantic API + Redmine view | `docker/local-plugins/cosmosys_exchange_api` | Optional plugin; migrations and 17 service/API assertions tested in isolation |
| Local dictation | `clients/IA-local/dictado.py` | Windows desktop prototype; capture/retry/review unit tests; requires audio and model setup |
| Local transcription and meeting minutes | `clients/IA-local/actas.py` | Windows desktop prototype; generated drafts require review; inference not deterministic |
| Remote backup download | `clients/maintenance/backup.ps1` | Parameterized maintenance helper; restore validation remains required |

Earlier `editorial-app` and `copy-paste-app` work directories are development
snapshots of the exchange client, not separate products. Their current code is
represented by the exchange client above. Project-specific content import and
reorganization scripts are not generic tools and contain private material; they
are intentionally not published. The old SSH Ruby bridge is superseded by the
plugin's `lib/text_bridge.rb`. Existing upstream backup/restore scripts remain
the supported server-side backup implementation.

## Desktop exchange

Python 3.12 with Tk is required. No third-party Python package is needed for
the codec. Configure `COSMOSYS_URL`, `COSMOSYS_LOGIN`,
`COSMOSYS_PASSWORD_FILE` (and `CGROL_*` for CGRol). The password files must be
outside this checkout and readable only by the account running the tool. Enable
Redmine REST and the exchange plugin in each destination. Run:

```sh
python clients/Intercambio-textos/app.py
python -m unittest discover -s clients/Intercambio-textos -v
```

Keep the generated `.exchange-key` securely: existing exported documents depend
on it. The importer accepts its own exported document format, not arbitrary Word
files. Copying an exported fragment and editing its title/body is supported by
the codec, but editing the hierarchy and moving sections needs explicit review.

## Dictation and minutes

Windows/Python 3.12/Tk, a microphone, faster-whisper, sounddevice, CUDA libraries
for GPU mode, and a local Ollama installation are required. `requirements-tested.txt`
records the original inference environment; it is not a portable dependency lock.
Install the direct dependencies from `requirements.txt` in a separate venv.
Download models separately before using offline mode; weights are not in Git.
Whisper's cache is `clients/IA-local/models/whisper`; Ollama's cache is
`clients/IA-local/models/ollama`. The optional Windows auto-launcher expects
`clients/IA-local/ollama/ollama.exe`; alternatively start Ollama yourself on
127.0.0.1:11434 with that model directory and cloud disabled.

Configure the same Redmine environment variables as the exchange client.
`WHISPER_DEVICE` defaults to `cuda`, `WHISPER_DEVICE_INDEX` to `0`,
`WHISPER_COMPUTE_TYPE` to `float16`, `WHISPER_MODEL` to `large-v3`, and
`OLLAMA_MODEL` to `qwen3:8b`. For CPU use set device `cpu` and compute type `int8`.
Run `python clients/IA-local/dictado.py` or `python clients/IA-local/actas.py`.
Select a project, record/import audio, review the transcription/draft, and save
explicitly. Audio and transcripts are local private data; define retention
before regular use. These tools do not implement browser dictation, SSO, LDAP,
speaker identification or phonetic IPA transcription.

## Verification recorded on 2026-10-23

The full `scripts/validate-deployment.sh requirements exchange` run completed
successfully in a disposable VM deployment: image build, migrations, bootstrap,
healthy application and upstream runner checks. The normal installed instance
was not changed. Python unit tests pass: 2 manager tests, 9 exchange/REST tests,
and 3 dictation tests with mocked audio. Plugin service/API coverage has 17
passing assertions. CI has been added; its remote result must be checked separately.

## Release gates still open

- Validate the base variant and backup/restore suites; requirements+exchange passed.
- Exercise GUI workflows, clean installation, Word copy/paste and hierarchy round trips.
- Exercise real microphone/GPU inference on a fresh installation; the unit tests mock audio.
- Review service-account delegation, cross-project permissions and semantic audit history.
- Agree with maintainers whether standalone clients belong in a separate repository.

Do not describe this branch as production-ready until these gates are closed.
