# Experimental semantic relations and reversible text exchange

This proposal adds an opt-in `exchange` set to the existing optional-plugin
catalog. It is disabled by default. No cosmoSys or Requirements source file is
patched. The plugin is temporarily vendored under
`docker/local-plugins/cosmosys_exchange_api` so this draft can be downloaded and
reviewed as a single branch. Maintainers may prefer to extract it to its own
repository before merging; the catalog supports that change.

## What is included

- Versioned JSON snapshot and optimistic, transactional text-change endpoints.
- A `Relaciones` project tab and a JSON API for typed links between visible
  issues, including cross-project links when the caller may edit both ends.
- Separate tables for issue types and relations. Issue text is not rewritten.
- Local browser clients for narrative and academic work under `clients/`.
  They share implementation, but run separate processes, sessions and SQLite
  stores. Their Word codec carries signed stable identities and supports a
  preview before applying corrections.

The ontology is deliberately small: universe, character, place, event, work,
unit, track, source, policy and collection. Relations include `belongs_to`,
`set_in`, `part_of`, `features`, `depicts`, `accompanies`, `adapts`,
`derived_from`, `governed_by` and `groups`. Domain/range combinations are listed
in the project tab. A work represents a universe; it is not typed as an instance
of that universe. Narrative order and world chronology remain distinct.

## Enable on a disposable instance first

Follow the normal provisioning/update workflow with `exchange` in
`COSMOSYS_PLUGINS`. No extra tools or gems are needed. The normal migration
service applies the plugin migration. PostgreSQL is required: writes use a
transaction-level advisory lock to serialize validation and mutation.

Back up the database and files before enabling on an existing instance. This
extension creates two tables and journals semantic edits on source issues.
Disabling the plugin preserves its data. Rolling back its migration drops those
tables; that is destructive and must not be used as a routine disable operation.

## REST endpoints

- `GET /projects/:id/exchange/v1/snapshot.json`
- `POST /projects/:id/exchange/v1/changes.json`
- `POST /projects/:id/exchange/v1/nodes.json`
- `GET /projects/:id/semantic.json`
- `POST /projects/:id/semantic/types.json`
- `POST /projects/:id/semantic/links.json`

Use normal Redmine API authentication. The source issue must belong to the
project in the URL. Both relation endpoints must be visible and editable by the
caller. A relation is hidden if either endpoint is invisible. Source journals
do not disclose target IDs or provenance to source-only readers.

Type payload: `issue_id`, `kind`, `revision` (-1 for a new assignment).
Link payload: `source_id`, `target_id`, `predicate`, `revision` (-1 for new),
`status` (`proposed`, `approved`, `rejected`) and nonempty `provenance`.
Approval additionally requires `confirm_approval=1`. Updating a link uses the
same endpoints/predicate and its returned revision. Rejecting retains the row
and deactivates its structural effect. There is no deletion endpoint.

Checks reject self-links, unknown or incompatible types, cycles in `part_of`,
`adapts` and `groups`, multiple active editorial containers, stale revisions,
and a type change that would invalidate existing links. A failed type change
rolls back even inside an enclosing transaction.

This is not OWL reasoning or SHACL, nor a full version/context ontology. It does
not infer canonical truth from a manuscript, check every world-continuity rule,
or automatically convert existing free-text links. Provenance is currently a
reviewable text field. Immutable per-revision semantic audit and richer
contextual roles remain future work; journals record the actor and edit event.

## Local clients

Python 3.11+; standard library only. Keep `clients/Gestores` and
`clients/Intercambio-textos` together. Configure:

```sh
export COSMOSYS_URL=http://localhost:3080
export COSMOSYS_LOGIN=editor
export COSMOSYS_PASSWORD_FILE=/private/path/editor-password
export COSMOSYS_ALLOWED_LOGINS=editor
python clients/Gestores/server.py historias --serve
python clients/Gestores/server.py academico --serve
```

On Windows, set the same environment variables in PowerShell. Ports are 3110
and 3120 and bind only to loopback. The optional launcher without `--serve`
is currently Windows-specific. Clients use a service account: logging into a
client does **not** delegate the user's identity for later writes. Only allow
users trusted to act through that service account. This is not a multi-tenant
or LAN deployment, and no LDAP/OIDC integration is provided here.

Client data, signing keys, DOCX files, credentials and private manuscripts are
excluded from the repository. Back up local SQLite metadata and the signing
key separately from Redmine. The configured backend URL is used by the HTTP
adapter; some navigation links in this initial UI still assume localhost:3080.
Automatic APA formatting and prose-to-screenplay generation are not included.

## Verification

Python client tests:

```sh
python -m unittest discover -s clients/Gestores -v
```

For Ruby tests, create a **disposable** private project and administrator account
with no real content. Set `SEMANTIC_TEST_PROJECT` and `SEMANTIC_TEST_USER` to
their identifiers/logins (defaults: `semantic-fixture`, `semantic_editor`). Enable
Redmine's REST API, migrate the plugin and run:

```sh
bundle exec rails runner plugins/cosmosys_exchange_api/test/semantic_graph_test.rb
```

Fixture issues and relation writes roll back. HTTP tests use a token for the
test account. Do not run this test suite on a shared production instance.

Verified locally: plugin migration and service/API tests on Redmine 7.0.1,
PostgreSQL 16, cosmoSys 0.1.6 / Requirements 0.3.1, and the deployment's current
pins cosmoSys 0.1.11 / Requirements 0.3.3. The full Docker image build and both
complete deployment validation suites must also pass before merging; isolated
plugin tests are not a substitute for those suites.

## Review boundaries

This is a draft proposal. There is no request to merge automatically or change
the default plugin set. Please review plugin placement, permissions, schema,
identity strategy and whether the clients belong in a separate repository.
Original upstream copyright and GPL-3.0 licence are retained. No private content,
database dumps, local environment files or account secrets belong in this PR.
