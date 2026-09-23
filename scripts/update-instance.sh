#!/bin/sh
set -eu

# Compares the version an instance is running with the version this deployment
# declares, and updates the instance to it. The version of an instance lives in
# its own environment file, so instances on one host update independently of
# each other and of the checkout they share.

. "$(dirname -- "$0")/deployment-lib.sh"

usage() {
  cat >&2 <<EOF
Usage: COSMOSYS_ENV_FILE=FILE $0 [--check] [--yes] [--pins FILE]
       [--source REF] [--allow-stale-deployment] [--timeout SECONDS]

Reads the version the instance runs from its container labels and the version
this deployment declares from REF (origin/main by default), and updates the
instance to it: backup, new pins in the instance environment file, image,
recreation and verification. A failure restores the previous pins and the
previous image, which does not undo a migration that already ran.

  --check                   Report and change nothing.
  --yes                     Apply on an instance whose COSMOSYS_UPDATE_MODE is
                            manual. Instances set to auto need no confirmation.
  --pins FILE               Take the declared versions from FILE (KEY=VALUE)
                            instead of from a git reference.
  --source REF              Git reference to read the declared versions from.
  --allow-stale-deployment  Apply although this checkout differs from REF in
                            the files that end up in the image.
  --timeout SECONDS         How long to wait for the instance to become
                            healthy, 300 by default.

Exit status: 0 up to date or updated, 10 an update is available and was not
applied, 4 another update of this instance is already running, 3 refused,
2 usage or configuration error, 1 the update failed.
EOF
}

check_only=0
assume_yes=0
allow_stale=0
pins_file=
source_ref=${COSMOSYS_UPDATE_SOURCE_REF:-origin/main}
wait_timeout=${COSMOSYS_UPDATE_TIMEOUT:-300}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --yes) assume_yes=1; shift ;;
    --allow-stale-deployment) allow_stale=1; shift ;;
    --pins|--source|--timeout)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      case "$1" in
        --pins) pins_file=$2 ;;
        --source) source_ref=$2 ;;
        --timeout) wait_timeout=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$wait_timeout" in
  ''|*[!0-9]*)
    echo "--timeout must be a number of seconds" >&2
    exit 2
    ;;
esac
if [ -n "$pins_file" ] && [ ! -f "$pins_file" ]; then
  echo "Pins file does not exist: $pins_file" >&2
  exit 2
fi

instance_env=${COSMOSYS_ENV_FILE:-"$deployment_repository_dir/.env"}
variant=$(deployment_variant)
database_mode=$(deployment_db_mode)
update_mode=$(deployment_setting COSMOSYS_UPDATE_MODE manual)

case "$update_mode" in
  manual|auto) ;;
  *)
    echo "COSMOSYS_UPDATE_MODE must be manual or auto" >&2
    exit 2
    ;;
esac

# The running container is the only trustworthy description of what an instance
# actually runs: an environment file can already name a version that has not
# been built or activated yet.
redmine_container=$(deployment_compose ps -q redmine)
if [ -z "$redmine_container" ]; then
  echo "The redmine service is not running; start the instance before updating it" >&2
  exit 2
fi

running_image=$(docker inspect --format '{{.Config.Image}}' "$redmine_container")
running_cosmosys=$(deployment_container_label "$redmine_container" eu.cosmobots.cosmosys.revision)
running_rspreadsheet=$(deployment_container_label "$redmine_container" eu.cosmobots.rspreadsheet.revision)
running_cosmosys_req=$(deployment_container_label "$redmine_container" eu.cosmobots.cosmosys-req.revision)

# An instance provisioned before the variant was recorded runs the Requirements
# image while its environment file says nothing, so it resolves to the base
# variant. Updating it then would rebuild it as the base variant and take the
# requirements plugin away from it.
if [ "$variant" = base ] && [ "$running_cosmosys_req" != unknown ]; then
  echo "This instance runs cosmoSys Requirements $running_cosmosys_req, but its" >&2
  echo "environment file does not say so and it resolves to the base variant." >&2
  echo "Add COSMOSYS_VARIANT=requirements to $instance_env before updating it." >&2
  exit 3
fi

# Prints one KEY=VALUE setting out of the text on standard input.
declared_setting() {
  sed -n "s/^$1=//p" | tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

# Prints the default of a Compose interpolation such as ${COSMOSYS_IMAGE:-...},
# which is where the image names of this deployment are declared.
declared_compose_image() {
  sed -n "s/.*\${$1:-\([^}]*\)}.*/\1/p" | head -n 1
}

deployment_drift=unknown

if [ -n "$pins_file" ]; then
  declared_env=$(cat "$pins_file")
  declared_compose=$declared_env
  declared_requirements=$declared_env
else
  if ! git -C "$deployment_repository_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$deployment_repository_dir is not a git checkout, so the declared" >&2
    echo "versions cannot be read from $source_ref. Pass --pins instead." >&2
    exit 2
  fi
  # Only a remote-tracking reference is worth fetching, and it says by itself
  # which remote to fetch from. A local reference, a tag or the reference of
  # another checkout is read as it is.
  source_full_ref=$(git -C "$deployment_repository_dir" \
    rev-parse --symbolic-full-name "$source_ref" 2>/dev/null || true)
  case "$source_full_ref" in
    refs/remotes/*)
      source_remote=${source_full_ref#refs/remotes/}
      source_remote=${source_remote%%/*}
      if ! git -C "$deployment_repository_dir" fetch --quiet "$source_remote"; then
        echo "Cannot fetch from $source_remote. An unattended update needs a read-only" >&2
        echo "deploy key on this host, because no SSH agent is forwarded to it." >&2
        exit 1
      fi
      ;;
  esac
  if ! git -C "$deployment_repository_dir" rev-parse --verify --quiet "$source_ref" >/dev/null; then
    echo "Unknown git reference: $source_ref" >&2
    exit 2
  fi
  declared_env=$(git -C "$deployment_repository_dir" show "$source_ref:.env.example")
  declared_compose=$(git -C "$deployment_repository_dir" show "$source_ref:compose.yml")
  declared_requirements=$(git -C "$deployment_repository_dir" show "$source_ref:compose.requirements.yml")

  # Everything that ends up inside the image, so that a stale checkout cannot
  # publish something else under the image tag that names those revisions.
  if git -C "$deployment_repository_dir" diff --quiet "$source_ref" -- \
    Dockerfile compose.yml compose.requirements.yml compose.shared-db.yml \
    compose.proxy.yml config bootstrap; then
    deployment_drift=no
  else
    deployment_drift=yes
  fi
fi

declared_cosmosys=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_REVISION)
declared_cosmosys_req=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_REQ_REVISION)
declared_rspreadsheet=$(printf '%s\n' "$declared_env" | declared_setting RSPREADSHEET_REVISION)
declared_redmine_image=$(printf '%s\n' "$declared_env" | declared_setting REDMINE_IMAGE)
declared_postgres_image=$(printf '%s\n' "$declared_env" | declared_setting POSTGRES_IMAGE)
declared_image=$(printf '%s\n' "$declared_compose" | declared_compose_image COSMOSYS_IMAGE)
declared_req_image=$(printf '%s\n' "$declared_requirements" | declared_compose_image COSMOSYS_REQ_IMAGE)

if [ -n "$pins_file" ]; then
  # A pins file may name the image explicitly instead of relying on Compose.
  pins_image=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_IMAGE)
  pins_req_image=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_REQ_IMAGE)
  declared_image=${pins_image:-$declared_image}
  declared_req_image=${pins_req_image:-$declared_req_image}
fi

if [ "$variant" = requirements ]; then
  declared_reference=$declared_req_image
else
  declared_reference=$declared_image
fi

for required in declared_cosmosys declared_rspreadsheet declared_redmine_image \
  declared_postgres_image declared_reference; do
  eval "required_value=\$$required"
  if [ -z "$required_value" ]; then
    echo "The declared versions are incomplete: ${required#declared_} is missing" >&2
    exit 2
  fi
done

printf 'Instance %s, %s variant, %s database.\n' \
  "$(deployment_setting COMPOSE_PROJECT_NAME cosmosys)" "$variant" "$database_mode"
printf 'Running:  %s\n' "$running_image"
printf '          cosmoSys %s' "$running_cosmosys"
if [ "$variant" = requirements ]; then
  printf ', cosmoSys Requirements %s' "$running_cosmosys_req"
fi
printf ', rspreadsheet %s\n' "$running_rspreadsheet"
printf 'Declared: %s\n' "$declared_reference"
printf '          cosmoSys %s' "$declared_cosmosys"
if [ "$variant" = requirements ]; then
  printf ', cosmoSys Requirements %s' "$declared_cosmosys_req"
fi
printf ', rspreadsheet %s\n' "$declared_rspreadsheet"

if [ "$deployment_drift" = yes ]; then
  echo "Warning: this checkout differs from $source_ref in files that end up in" >&2
  echo "the image, so a build here would not match what $source_ref describes." >&2
fi

if [ "$running_image" = "$declared_reference" ]; then
  echo "The instance is up to date."
  exit 0
fi

echo "An update is available."

if [ "$check_only" = 1 ]; then
  exit 10
fi

if [ "$update_mode" = manual ] && [ "$assume_yes" = 0 ]; then
  echo "This instance is set to manual updates; rerun with --yes to apply it."
  exit 10
fi

if [ "$deployment_drift" = yes ] && [ "$allow_stale" = 0 ]; then
  echo "Refusing to update from a checkout that differs from $source_ref in the" >&2
  echo "files that end up in the image. The image built here would be tagged with" >&2
  echo "the revisions it declares while containing something else, and that image" >&2
  echo "outlives this update: it is what a rollback starts again and what every" >&2
  echo "backup manifest records." >&2
  echo "Update the checkout, or pass --allow-stale-deployment deliberately." >&2
  exit 3
fi

# A major PostgreSQL version is not an update but a migration with its own dump
# and restore, so this script never starts one behind the operator's back.
if [ "$database_mode" = local ]; then
  database_container=$(deployment_compose ps -q db)
  if [ -n "$database_container" ]; then
    running_postgres=$(docker inspect --format '{{.Config.Image}}' "$database_container")
    running_major=$(printf '%s\n' "$running_postgres" | sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p')
    declared_major=$(printf '%s\n' "$declared_postgres_image" | sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p')
    if [ -n "$running_major" ] && [ -n "$declared_major" ] &&
      [ "$running_major" != "$declared_major" ]; then
      echo "Refusing to update: PostgreSQL would go from $running_major to $declared_major." >&2
      echo "A major version needs its own dump and restore, not a recreation." >&2
      exit 3
    fi
  fi
fi

# Two updates of one instance at the same time would run two recreations
# against the same Compose project, so the second one waits for another day
# rather than for the first one: a timer firing while somebody updates by hand
# has nothing useful to do. Instances are locked one by one, so different
# instances on one host still update in parallel.
lock_name=$(printf '%s' "$(deployment_setting COMPOSE_PROJECT_NAME cosmosys)" |
  tr -c 'A-Za-z0-9_.-' '_')
lock_directory="${COSMOSYS_UPDATE_LOCK_DIR:-${TMPDIR:-/tmp}}/cosmosys-update-$lock_name.lock"

lock_acquired=0
work_directory=
rollback_needed=0

cleanup() {
  if [ "$lock_acquired" = 1 ]; then
    rm -rf -- "$lock_directory"
  fi
  if [ -n "$work_directory" ] && [ "$rollback_needed" = 0 ]; then
    rm -rf -- "$work_directory"
  fi
}
trap cleanup EXIT HUP INT TERM

if ! mkdir "$lock_directory" 2>/dev/null; then
  echo "Another update of this instance is already running." >&2
  if [ -r "$lock_directory/pid" ]; then
    echo "Its lock is $lock_directory, held by process $(cat "$lock_directory/pid")." >&2
  else
    echo "Its lock is $lock_directory." >&2
  fi
  echo "Remove that directory only after making sure that no update is running." >&2
  exit 4
fi
lock_acquired=1
printf '%s\n' "$$" >"$lock_directory/pid"

work_directory=$(mktemp -d)

(umask 077 && cat "$instance_env" >"$work_directory/previous.env")

# Replaces one setting in place, keeping the file's own permissions and inode.
set_instance_setting() {
  awk -v key="$1" -v value="$2" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 {
      if (!found) {
        print key "=" value
        found = 1
      }
      next
    }
    { print }
    END { if (!found) print key "=" value }
  ' "$instance_env" >"$work_directory/instance.env"
  cat "$work_directory/instance.env" >"$instance_env"
}

restore_previous_version() {
  echo "Restoring the previous version of the instance..." >&2
  cat "$work_directory/previous.env" >"$instance_env"
  if deployment_compose up -d --wait --wait-timeout "$wait_timeout" redmine >&2; then
    echo "The instance runs its previous image again." >&2
  else
    echo "The instance did not come back up on its previous image." >&2
  fi
  cat >&2 <<EOF

The database was not restored. If the update had already run its migrations,
the previous image is running against a migrated schema, and the only way back
is the backup taken before the update:

  RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \\
    COSMOSYS_ENV_FILE=$instance_env \\
    $deployment_repository_dir/scripts/restore.sh $backup_directory

A copy of the environment file as it was before the update is kept in
$work_directory/previous.env
EOF
}

update_failed() {
  echo "$1" >&2
  rollback_needed=1
  restore_previous_version
  exit 1
}

echo "Backing up the instance before updating it..."
if ! backup_directory=$("$deployment_repository_dir/scripts/backup.sh" \
  ${COSMOSYS_BACKUP_ROOT:+"$COSMOSYS_BACKUP_ROOT"}); then
  echo "The backup failed, so the instance was left untouched." >&2
  exit 1
fi
echo "Backup: $backup_directory"

set_instance_setting COSMOSYS_REVISION "$declared_cosmosys"
set_instance_setting RSPREADSHEET_REVISION "$declared_rspreadsheet"
set_instance_setting REDMINE_IMAGE "$declared_redmine_image"
set_instance_setting POSTGRES_IMAGE "$declared_postgres_image"
set_instance_setting COSMOSYS_IMAGE "$declared_image"
if [ "$variant" = requirements ]; then
  set_instance_setting COSMOSYS_REQ_REVISION "$declared_cosmosys_req"
  set_instance_setting COSMOSYS_REQ_IMAGE "$declared_req_image"
fi

# The only step that knows where an image comes from. With a registry this
# becomes a pull and nothing else in this script changes.
update_acquire_image() {
  deployment_compose build redmine
}

image_started=$(date +%s)
echo "Building $declared_reference..."
if ! update_acquire_image; then
  update_failed "The image could not be built."
fi
echo "Image ready in $(($(date +%s) - image_started)) s."

echo "Recreating the instance..."
if ! deployment_compose up -d --wait --wait-timeout "$wait_timeout" redmine; then
  deployment_compose logs --no-color --tail 100 migrate bootstrap redmine >&2 || true
  update_failed "The instance did not become healthy within $wait_timeout s."
fi

updated_container=$(deployment_compose ps -q redmine)
if [ -z "$updated_container" ]; then
  update_failed "The redmine service is not running after the update."
fi

updated_cosmosys=$(deployment_container_label "$updated_container" eu.cosmobots.cosmosys.revision)
if [ "$updated_cosmosys" != "$declared_cosmosys" ]; then
  update_failed "The instance runs cosmoSys $updated_cosmosys instead of $declared_cosmosys."
fi
if [ "$variant" = requirements ]; then
  updated_cosmosys_req=$(deployment_container_label "$updated_container" eu.cosmobots.cosmosys-req.revision)
  if [ "$updated_cosmosys_req" != "$declared_cosmosys_req" ]; then
    update_failed "The instance runs cosmoSys Requirements $updated_cosmosys_req instead of $declared_cosmosys_req."
  fi
fi

expected_plugins=cosmosys
if [ "$variant" = requirements ]; then
  expected_plugins="cosmosys cosmosys_req"
fi
if ! deployment_compose exec -T redmine bundle exec rails runner \
  "expected = %w[$expected_plugins]; actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); missing = expected - actual; abort(\"missing plugins: #{missing.join(', ')}\") unless missing.empty?"; then
  update_failed "The updated instance does not register the expected plugins."
fi

cat <<EOF
The instance is updated and healthy.
  image:  $declared_reference
  backup: $backup_directory
EOF
