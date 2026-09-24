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
for example, with `openssl rand -hex 64`. Building the images needs nothing but
Docker and network access to github.com: the plugin repositories are public and
are cloned anonymously over HTTPS.

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

An instance records its variant in `COSMOSYS_VARIANT`, which
`provision-instance.sh` writes into that file, so backup and restore need no
further argument to reach a Requirements instance. A shell variable that
contradicts the file is an error rather than a silent override. Restore is
intentionally explicit and destructive:

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

An instance with its own environment file names its variant there, so
`scripts/compose.sh` resolves the files it needs and every Compose command
reads the same for both variants:

```sh
COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/compose.sh up -d
```

The web service binds to `127.0.0.1:3000` by default. Put a TLS reverse proxy
in front of it or deliberately change `COSMOSYS_BIND_ADDRESS` and
`COSMOSYS_HTTP_PORT`.

Database and Redmine files use named persistent volumes. Do not use `down -v`
on an installation whose data must survive.

The default Redmine and PostgreSQL images, plugin sources and rspreadsheet
source are pinned to immutable revisions. Updating one is a deliberate change
that must be validated for both deployment variants.

## Components and source revisions

This deployment installs two cosmoSys plugins on top of the pinned Redmine
image. For every change, each plugin repository declares a semantic version
and a release tag; the deployment pins the exact commit (and therefore the
tagged release) that was validated.

Current pins (see `.env.example` and `compose*.yml`):

| Component | Version | Commit | Tag |
| --- | --- | --- | --- |
| Redmine | 7.0.1 | manifest (see `.env.example`) | n/a |
| [cosmoSys](https://github.com/cosmoBots/cosmoSys) | 0.1.5 | `312b560` | `0.1.5` + localization |
| cosmoSys Requirements | 0.3.1 | `9479098` | `0.3.1` + localization |
| rspreadsheet | pin | `c01d413` | n/a |

The base variant installs `cosmoSys` only; the requirements variant adds
`cosmoSys Requirements`. The image tags embed the short commit of each plugin
(`cosmobots/cosmosys:<cosmosys_short>-redmine-7.0.1` and
`cosmobots/cosmosys-req:<cosmosys_short>-<req_short>-redmine-7.0.1`), so the
running image identifies the exact plugin revision.

**Versioning strategy.** The plugins own their version numbers (declared in
their `init.rb`) and their release tags; the deployment repository does not
duplicate them. This repository has no version number of its own: it follows
the plugins and pins the exact commit it validated. Ordinarily `init.rb` and
the release tag agree with that commit. A translation-only maintenance commit
may retain the current semantic version without moving an existing tag, when it
changes no runtime contract, schema or migration; the table must identify that
exception and the immutable `COSMOSYS_REVISION` / `COSMOSYS_REQ_REVISION` remain
the deployment authority. Validate both variants before committing new pins.

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

## Updating an instance

The version of an instance is the image it runs, and that image tag names the
plugin revisions built into it. `scripts/update-instance.sh` compares it with
the version this repository declares and moves the instance to it:

```sh
COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/update-instance.sh --check
```

`--check` changes nothing and exits 0 when the instance is up to date and 10
when an update is available. Without it the script applies the update: it backs
the instance up, writes the new revisions into the instance environment file,
builds the image, recreates the instance, waits for it to become healthy and
verifies that the new container carries the revisions that were asked for and
registers the expected plugins.

The declared version is read from `origin/main` with `git fetch` and
`git show`, never from the working tree, so the script works the same on a
plain clone and on a submodule with a detached HEAD, and it never modifies the
checkout. A host with no SSH agent needs a read-only deploy key for that fetch;
without one the script stops as a configuration error, having touched nothing.
`--source REF` reads another reference, and `--pins FILE` takes the revisions
from a file, which is how one instance is held at an older combination.

Because those revisions end up in the instance environment file, every instance
carries its own version: two instances sharing a checkout can run different
combinations, and updating the checkout does not move either of them.

Set `COSMOSYS_UPDATE_MODE` in the instance environment file to `manual` (the
default) or `auto`. A manual instance reports an available update and exits 10
without touching anything unless `--yes` is passed; an auto instance applies it
unattended. `systemd/` holds a template service and timer to instantiate once
per instance, and an example of the paths they read:

```sh
sudo cp systemd/cosmosys-update@.* /etc/systemd/system/
sudo cp systemd/cosmosys-update.conf.example /etc/default/cosmosys-update
sudo systemctl enable --now cosmosys-update@alpha.timer
```

A host with several instances is reported, or updated, in one command.
`scripts/update-instances.sh` runs the same script over every `<name>.env` file
of `COSMOSYS_INSTANCES_DIR`, one after another, passes its options through, ends
with one line per instance and exits with the most serious status of the host:

```sh
COSMOSYS_INSTANCES_DIR=/srv/cosmosys/instances \
  ./scripts/update-instances.sh --check
```

Each instance is locked while it is updated, so a scheduled update and a manual
one never recreate the same instance at once; the second one stops with status
4. Instances on one host still update in parallel with each other.

When an update fails, the script puts the previous revisions back in the
environment file and starts the previous image, which is still on the host.
That undoes the code but not the schema: if the migration had already run, the
way back is the backup the update took, and the script prints the `restore.sh`
command for it. For the same reason it refuses three situations rather than
attempting them: an environment file that contradicts the running image, such
as an instance provisioned before the variant was recorded, which would be
rebuilt as the base variant and lose its requirements plugin; a PostgreSQL
major version change, which needs its own dump and restore; and an update from a
checkout whose image-building files differ from `origin/main`, because the
image tag would then name revisions without describing what is inside it.

Validate the whole path, a successful update and a failed one, on a disposable
instance:

```sh
./scripts/validate-update.sh
```

[`docs/instance-updates.md`](docs/instance-updates.md) describes the sequence
step by step, with a diagram, what each step touches, where the point of no
return is and what a failure can cost.

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
password, and refuses to reuse an existing file, role or database.
`--http-port` sets the local HTTP port, which is otherwise chosen at random:

```sh
./scripts/provision-instance.sh --http-port 3101 alpha /srv/cosmosys/alpha.env
```

The generated file sets `COSMOSYS_VARIANT` and `COSMOSYS_DB_MODE=shared`, so
the deployment scripts add the overlays that instance needs when they receive
it through `COSMOSYS_ENV_FILE`, and `scripts/compose.sh` does the same for any
Compose command. Direct `docker compose` invocations must name the overlays:

```sh
COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/compose.sh up -d
COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/backup.sh
docker compose --env-file /srv/cosmosys/alpha.env \
  -f compose.yml -f compose.shared-db.yml up -d
```

Provision a Requirements instance with `--variant requirements`, which records
it in the environment file; only direct Compose commands then have to name
`compose.requirements.yml`. Give every instance a distinct
`COSMOSYS_HTTP_PORT`, or `0` for a random local port.

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

## Shared reverse proxy

One reverse proxy per host publishes the instances under their own host names.
It discovers them through Docker labels, so starting or stopping an instance
adds or removes its route without editing or reloading the proxy.

```sh
cp proxy/.env.example proxy/.env
docker compose -f proxy/compose.yml up -d --wait
```

The proxy is caddy-docker-proxy, the only service that publishes ports (80 and
443 by default). It reads the Docker API through a read-only socket proxy on an
internal network, so neither the proxy nor the instances mount the Docker
socket. Published instances join the external network `COSMOSYS_PROXY_NETWORK`
(`caddy_proxy` by default, as on the previous deployment). A host that already
runs caddy-docker-proxy can keep it: point that variable at its ingress network
and skip this project.

Provision an instance with a public host name to publish it:

```sh
./scripts/provision-instance.sh --hostname alpha.csys.example.org \
  --tls admin@example.org alpha /srv/cosmosys/alpha.env
```

`--tls` takes the e-mail address of the Let's Encrypt account, which requires
the name to resolve publicly to this host and ports 80 and 443 to be reachable,
or `internal` for certificates from Caddy's own authority. Without `--tls` the
script uses `COSMOSYS_PROXY_TLS` from the shell or `proxy/.env`. The generated
file sets `COSMOSYS_PROXY_MODE=shared`, so the scripts add `compose.proxy.yml`;
direct Compose commands must name it as well. The local HTTP port stays on the
loopback interface and is chosen at random, so instances never collide.

On first start the bootstrap sets Redmine's host name and protocol to the
public HTTPS address, unless an administrator has already changed them. A
wildcard DNS record such as `*.csys.example.org` lets new instances go live
without further DNS changes.

Validate routing, route removal and the isolation of the Docker API with a
disposable proxy and instance:

```sh
./scripts/validate-proxy.sh
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
operations policy. Give the scheduled process the optional
`COSMOSYS_COMPOSE_PROJECT` used by the deployment.

When the deployment is configured through its own environment file rather than
`.env`, also give the scheduled process `COSMOSYS_ENV_FILE` pointing at that
file; the variant comes from that file. A deployment that runs the Requirements
composition from `.env` gives the process `COSMOSYS_VARIANT=requirements`
instead.

- Copyright and authorship: cosmoBots.eu
- Contact: txinto@elporis.com
- Licence: GNU General Public License version 3; see `LICENSE`.
