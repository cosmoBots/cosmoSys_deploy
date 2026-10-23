# Independent development and attribution

The optional authoring clients and experimental AI services in this branch are
developed for the fpgulias project with assistance from OpenAI Codex. They are
not an official cosmoBots release and have not been approved by its maintainers.
Txinto must not be represented as the author of these additions.

This repository is a fork of cosmoBots/cosmoSys_deploy. Its upstream code,
copyright notices, Git history and GPL-3.0 license are retained. Attribution of
the additions does not replace attribution or licensing of the upstream work.

Development of new services takes place on `development/standalone-services`.
It is separate from `feature/semantic-exchange-review`, the branch submitted
in upstream draft PR #13. Pushing this development branch does not update that PR.

Current status: experimental development snapshot, not a production release.
The extracted minutes domain service and replaceable Ollama adapter are the
first modularization step. REST service hosting, transcription adapters and
publication adapters are still being implemented. Existing desktop tools
remain available and are not switched to this new implementation yet.

See `tool-inventory.md` for the previous implementation's validation and gaps.
New tests: `python -m unittest discover -s services -v`.

Future upstream contributions should be discussed with maintainers first and
presented as explicitly attributed changes. No automatic upstream merge or
endorsement is implied by a fork or pull request.
