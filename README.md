# cosmoSys deployment

Reproducible Docker Compose deployment for the current cosmoSys alpha. It is
intended for controlled persistent evaluation and is not yet declared
production-ready.

The repository provides two variants from one common definition:

- Redmine + cosmoSys;
- Redmine + cosmoSys + cosmoSys Requirements.

## Configure

```sh
cp .env.example .env
```

Replace `POSTGRES_PASSWORD` and `REDMINE_SECRET_KEY_BASE`. Generate the latter,
for example, with `openssl rand -hex 64`. The repository currently uses SSH
forwarding during image construction because the plugin repositories are
private; load an authorized GitHub key into your SSH agent first.

Set `COSMOSYS_INITIAL_ADMIN_PASSWORD` before the first start. The bootstrap
replaces Redmine's unsafe `admin`/`admin` credentials before the web service is
exposed and clears the forced password-change flag. It only acts while the
account still has the untouched default password and no successful login; a
later bootstrap never resets an administrator-managed password. For secret
mounts, leave that variable empty and set
`COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE` to the mounted file instead.

Validate both effective configurations:

```sh
./scripts/check-config.sh
```

Run an isolated end-to-end validation of both variants (temporary containers
and volumes are removed afterwards):

```sh
./scripts/validate-deployment.sh
```

Pass `base` or `requirements` to validate only one variant. Set
`KEEP_VALIDATION_STACK=1` to retain a failed or successful validation stack
for inspection; its generated Compose project name is printed before startup.

## Backup and restore

Back up the running database and Redmine file store into a timestamped,
checksummed directory:

```sh
./scripts/backup.sh
```

The manifest describes the running stack rather than the current configuration:
its Compose project, database, Redmine image and the source revisions labelled
in that image. An environment file that already names a revision not yet built
or activated therefore cannot misreport a backup. Images built before those
labels existed record `unknown` until they are rebuilt.

An instance configured through a file other than `.env` is addressed with
`COSMOSYS_ENV_FILE`, which backup, restore and `scripts/bootstrap-content.sh`
pass to Compose. A relative path resolves from the current directory, and a
`COMPOSE_PROJECT_NAME` in that file selects the Compose project unless
`COSMOSYS_COMPOSE_PROJECT` overrides it:

```sh
COSMOSYS_ENV_FILE=/srv/cosmosys/instance.env ./scripts/backup.sh
```

For the Requirements composition, set `COSMOSYS_VARIANT=requirements` for both
backup and restore. Restore is intentionally explicit and destructive:

```sh
RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \
  ./scripts/restore.sh backups/20260828T120000Z
```

The restore verifies every hash before stopping Redmine. It replaces only the
database and `files` volume belonging to the selected Compose deployment; the
database container remains online. Keep `.env` and the backup outside source
control and copy backups to storage outside the Docker host.

The destructive path has its own disposable integration test:

```sh
./scripts/validate-backup-restore.sh
```

## Base variant

```sh
docker compose -f compose.yml build
docker compose -f compose.yml up -d
```

## Requirements variant

```sh
docker compose -f compose.yml -f compose.requirements.yml build
docker compose -f compose.yml -f compose.requirements.yml up -d
```

The web service binds to `127.0.0.1:3000` by default. Put a TLS reverse proxy
in front of it or deliberately change `COSMOSYS_BIND_ADDRESS` and
`COSMOSYS_HTTP_PORT`.

Database and Redmine files use named persistent volumes. Do not use `down -v`
on an installation whose data must survive.

The default Redmine and PostgreSQL images, plugin sources and rspreadsheet
source are pinned to immutable revisions. Updating one is a deliberate change
that must be validated for both deployment variants.

Those revisions and the base image are declared only in the Compose files and
`.env`, so the image is built through Compose. A direct `docker build` has to
pass them as build arguments and stops with an explicit message when one is
missing.

Database configuration is supplied as an ERB file that consumes only the
standard container environment variables. This also lets the one-shot
migration service boot Rails before the web service is started.

On a new database that service migrates Redmine, loads its initial data using
`REDMINE_LANG` (`en` by default), and then migrates the plugins. The operations
are safe to rerun on later starts.

The first login follows Redmine's normal initial-administrator procedure. The
initial content package creates public `csys_help` and private
`csys_admin_help` wiki projects. Software-managed `csInt_` pages are refreshed
idempotently; ordinary facade pages are created once and then belong to the
administrator. Run `scripts/bootstrap-content.sh` to reapply the current
package explicitly.

## Shared PostgreSQL server

Several instances on one host can share a single PostgreSQL server instead of
running a database container each. Every instance keeps its own role and
database. The roles are neither superusers nor allowed to create databases,
and they cannot connect to the databases of other instances.

Copy `shared-db/.env.example` to `shared-db/.env`, replace
`COSMOSYS_DB_ADMIN_PASSWORD` and start the shared server once:

```sh
docker compose -f shared-db/compose.yml up -d --wait
```

The administrator account is used only to provision instances. The server
publishes no port: instances reach it through the external network
`COSMOSYS_DB_NETWORK` (`csys_db` by default) under the host name
`COSMOSYS_DB_HOST` (`csys-db`).

Provision each instance with a unique name and a new environment file kept
outside source control. The script creates the role and the database, generates
the database password, `REDMINE_SECRET_KEY_BASE` and the initial administrator
password, and refuses to reuse an existing file, role or database. The optional
last argument is the local HTTP port:

```sh
./scripts/provision-shared-db.sh alpha /srv/cosmosys/alpha.env 3101
```

The generated file sets `COSMOSYS_DB_MODE=shared`, so the deployment scripts
add `compose.shared-db.yml` by themselves when they receive it through
`COSMOSYS_ENV_FILE`. Direct Compose commands must name the overlay:

```sh
docker compose --env-file /srv/cosmosys/alpha.env \
  -f compose.yml -f compose.shared-db.yml up -d
COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/backup.sh
```

For the Requirements variant, add `compose.requirements.yml` to direct commands
and `COSMOSYS_VARIANT=requirements` to the scripts. Give every instance a
distinct `COSMOSYS_HTTP_PORT`, or `0` for a random local port.

In shared mode, backups and restores run the PostgreSQL tools in a disposable
`db-client` container with the instance credentials. A restore removes the
objects owned by the instance role and loads the dump into the same database,
leaving other instances untouched.

Each instance uses at most five connections from the Rails pool, plus
short-lived ones for migrations, bootstrap and backups. Provisioned roles are
limited to `COSMOSYS_DB_CONNECTION_LIMIT` (20) connections, and the default
`COSMOSYS_DB_MAX_CONNECTIONS` of 100 serves about fifteen instances. Stopping
or upgrading the shared server affects every instance that uses it, and the
overlay requires Docker Compose 2.20 or later.

Validate the shared mode end to end with two disposable instances:

```sh
./scripts/validate-shared-db.sh
```

## Periodic item-tree audit

Run the exhaustive, read-only audit against the active deployment with:

```sh
./scripts/audit-trees.sh
```

It exits successfully when every project tree is coherent. If it detects an
anomaly, it emits a structured JSON report, returns a non-zero status and
emails every active administrator with a configured address. It never repairs
data. Repair remains a separate, explicit administrator action.

The host administrator can schedule the same command with cron or a systemd
timer. For example, from this repository, a daily cron entry can invoke:

```cron
17 3 * * * cd /srv/cosmosys-deploy && ./scripts/audit-trees.sh >> var/tree-audit.log 2>&1
```

Create and rotate the host-side log directory according to the installation's
operations policy. For the Requirements composition, give the scheduled
process the same `COSMOSYS_VARIANT=requirements` and optional
`COSMOSYS_COMPOSE_PROJECT` environment used by the deployment.

When the deployment is configured through its own environment file rather than
`.env`, also give the scheduled process `COSMOSYS_ENV_FILE` pointing at that
file.

- Copyright and authorship: cosmoBots.eu
- Contact: txinto@elporis.com
- Licence: GNU General Public License version 3; see `LICENSE`.
