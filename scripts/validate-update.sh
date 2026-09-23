#!/bin/sh
set -eu

# Updates a disposable instance from the previous release to the version this
# checkout declares, and then fails an update on purpose to exercise the way
# back. The stack, its volumes and the images built here are removed
# afterwards, and nothing outside this validation is touched.

. "$(dirname -- "$0")/deployment-lib.sh"

# Everything comes from the generated environment file below.
unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDMINE_SECRET_KEY_BASE \
  COSMOSYS_INITIAL_ADMIN_PASSWORD COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE \
  COSMOSYS_HTTP_PORT COSMOSYS_DB_MODE COSMOSYS_PROXY_MODE COSMOSYS_VARIANT \
  COSMOSYS_ENV_FILE COMPOSE_PROJECT_NAME COSMOSYS_COMPOSE_PROJECT \
  COSMOSYS_REVISION COSMOSYS_REQ_REVISION RSPREADSHEET_REVISION \
  COSMOSYS_IMAGE COSMOSYS_REQ_IMAGE COSMOSYS_UPDATE_MODE

suffix=$$
validation_directory=$(mktemp -d)
baseline_image="cosmobots/cosmosys-update-validation:baseline-$suffix"
baseline_req_image="cosmobots/cosmosys-req-update-validation:baseline-$suffix"
target_image="cosmobots/cosmosys-update-validation:target-$suffix"
target_req_image="cosmobots/cosmosys-req-update-validation:target-$suffix"

export COSMOSYS_ENV_FILE="$validation_directory/instance.env"
export COSMOSYS_BACKUP_ROOT="$validation_directory/backups"

# The release the instance starts from. The target is whatever this checkout
# declares, so the validation follows the repository instead of a fixed pair.
baseline_revision=${COSMOSYS_UPDATE_BASELINE_REVISION:-7819c0bfb5ec3f95e3d696d05f5211763a234f61}
baseline_req_revision=${COSMOSYS_UPDATE_BASELINE_REQ_REVISION:-8b890276f434cc703697faebc36ade00c2571e64}

declared_setting() {
  sed -n "s/^$1=//p" "$deployment_repository_dir/.env.example" |
    tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

target_revision=$(declared_setting COSMOSYS_REVISION)
target_req_revision=$(declared_setting COSMOSYS_REQ_REVISION)
rspreadsheet_revision=$(declared_setting RSPREADSHEET_REVISION)
redmine_image=$(declared_setting REDMINE_IMAGE)
postgres_image=$(declared_setting POSTGRES_IMAGE)

if [ "$target_revision" = "$baseline_revision" ] &&
  [ "$target_req_revision" = "$baseline_req_revision" ]; then
  echo "This checkout declares the same revisions as the baseline, so there is" >&2
  echo "nothing to update. Set COSMOSYS_UPDATE_BASELINE_REVISION and" >&2
  echo "COSMOSYS_UPDATE_BASELINE_REQ_REVISION to an older release." >&2
  exit 2
fi

cleanup() {
  if [ "${KEEP_VALIDATION_STACK:-0}" = 1 ]; then
    echo "Keeping the validation stack and $validation_directory for inspection."
    return
  fi
  deployment_compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm -f "$baseline_image" "$baseline_req_image" \
    "$target_image" "$target_req_image" \
    "cosmobots/cosmosys-update-validation:broken-$suffix" \
    "cosmobots/cosmosys-req-update-validation:broken-$suffix" >/dev/null 2>&1 || true
  rm -rf -- "$validation_directory"
}
trap cleanup EXIT HUP INT TERM

umask 077
cat >"$COSMOSYS_ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=csys_update_validation_$suffix
COSMOSYS_VARIANT=requirements
COSMOSYS_UPDATE_MODE=manual
POSTGRES_DB=csys_update_validation
POSTGRES_USER=csys_update_validation
POSTGRES_PASSWORD=update-validation-database-password-$suffix
REDMINE_SECRET_KEY_BASE=update-validation-secret-key-base-$suffix
COSMOSYS_INITIAL_ADMIN_PASSWORD=update-validation-admin-password-$suffix
COSMOSYS_HTTP_PORT=0
COSMOSYS_REVISION=$baseline_revision
COSMOSYS_REQ_REVISION=$baseline_req_revision
RSPREADSHEET_REVISION=$rspreadsheet_revision
REDMINE_IMAGE=$redmine_image
POSTGRES_IMAGE=$postgres_image
COSMOSYS_IMAGE=$baseline_image
COSMOSYS_REQ_IMAGE=$baseline_req_image
EOF

cat >"$validation_directory/target.env" <<EOF
COSMOSYS_REVISION=$target_revision
COSMOSYS_REQ_REVISION=$target_req_revision
RSPREADSHEET_REVISION=$rspreadsheet_revision
REDMINE_IMAGE=$redmine_image
POSTGRES_IMAGE=$postgres_image
COSMOSYS_IMAGE=$target_image
COSMOSYS_REQ_IMAGE=$target_req_image
EOF

# A revision that does not exist fails while the image is being built, before
# any migration has run, which is the way back that has to work every time.
cat >"$validation_directory/broken.env" <<EOF
COSMOSYS_REVISION=0000000000000000000000000000000000000000
COSMOSYS_REQ_REVISION=$target_req_revision
RSPREADSHEET_REVISION=$rspreadsheet_revision
REDMINE_IMAGE=$redmine_image
POSTGRES_IMAGE=$postgres_image
COSMOSYS_IMAGE=cosmobots/cosmosys-update-validation:broken-$suffix
COSMOSYS_REQ_IMAGE=cosmobots/cosmosys-req-update-validation:broken-$suffix
EOF

update() {
  "$deployment_repository_dir/scripts/update-instance.sh" "$@"
}

instance_runner() {
  deployment_compose exec -T redmine bundle exec rails runner "$1"
}

running_revision() {
  deployment_container_label "$(deployment_compose ps -q redmine)" \
    eu.cosmobots.cosmosys.revision
}

instance_setting() {
  sed -n "s/^$1=//p" "$COSMOSYS_ENV_FILE" | tail -n 1
}

set_update_mode() {
  awk -v value="$1" '
    index($0, "COSMOSYS_UPDATE_MODE=") == 1 {
      print "COSMOSYS_UPDATE_MODE=" value
      next
    }
    { print }
  ' "$COSMOSYS_ENV_FILE" >"$validation_directory/mode.env"
  cat "$validation_directory/mode.env" >"$COSMOSYS_ENV_FILE"
}

echo "Starting the baseline instance on cosmoSys $baseline_revision..."
if ! deployment_compose up -d --wait --build redmine; then
  deployment_compose logs --no-color --tail 100 migrate bootstrap redmine >&2 || true
  exit 1
fi

instance_runner "
  User.create!(
    login: 'update_validation',
    firstname: 'Update',
    lastname: 'Validation',
    mail: 'update-validation@example.org'
  )
  abort('the help projects are missing before the update') unless
    Project.where(identifier: %w[csys_help csys_admin_help]).count == 2
"
deployment_compose exec -T redmine sh -c \
  "printf '%s' 'files-before-update' > /usr/src/redmine/files/csys-update-probe.txt"

echo "Checking that an available update is reported without applying it..."
update_status=0
update --check --pins "$validation_directory/target.env" || update_status=$?
if [ "$update_status" -ne 10 ]; then
  echo "--check returned $update_status instead of 10 on an outdated instance" >&2
  exit 1
fi
if [ "$(running_revision)" != "$baseline_revision" ]; then
  echo "--check changed the running instance" >&2
  exit 1
fi
if [ "$(instance_setting COSMOSYS_REVISION)" != "$baseline_revision" ]; then
  echo "--check changed the instance environment file" >&2
  exit 1
fi

echo "Checking that a manual instance is not updated without --yes..."
update_status=0
update --pins "$validation_directory/target.env" || update_status=$?
if [ "$update_status" -ne 10 ]; then
  echo "A manual instance returned $update_status instead of 10 without --yes" >&2
  exit 1
fi
if [ "$(running_revision)" != "$baseline_revision" ]; then
  echo "A manual instance was updated without --yes" >&2
  exit 1
fi

# An instance set to auto updates unattended, which is what the timer relies on.
set_update_mode auto

echo "Updating to cosmoSys $target_revision..."
update --pins "$validation_directory/target.env"

if [ "$(running_revision)" != "$target_revision" ]; then
  echo "The instance runs $(running_revision) instead of $target_revision" >&2
  exit 1
fi
if [ "$(instance_setting COSMOSYS_REVISION)" != "$target_revision" ]; then
  echo "The instance environment file was not updated" >&2
  exit 1
fi
if [ "$(instance_setting COSMOSYS_REQ_IMAGE)" != "$target_req_image" ]; then
  echo "The Requirements image was not pinned in the environment file" >&2
  exit 1
fi
if [ -z "$(find "$COSMOSYS_BACKUP_ROOT" -name manifest.env -print 2>/dev/null | head -n 1)" ]; then
  echo "The update did not leave a backup behind" >&2
  exit 1
fi

instance_runner "
  abort('the seeded user did not survive the update') unless
    User.find_by(login: 'update_validation')
  abort('the help projects did not survive the update') unless
    Project.where(identifier: %w[csys_help csys_admin_help]).count == 2
  abort('plugins are missing after the update') unless
    (%w[cosmosys cosmosys_req] - Redmine::Plugin.registered_plugins.keys.map(&:to_s)).empty?
"
file_probe=$(deployment_compose exec -T redmine \
  cat /usr/src/redmine/files/csys-update-probe.txt)
if [ "$file_probe" != files-before-update ]; then
  echo "The Redmine file store did not survive the update" >&2
  exit 1
fi

echo "Failing an update on purpose to exercise the way back..."
update_status=0
update --pins "$validation_directory/broken.env" >/dev/null 2>&1 || update_status=$?
if [ "$update_status" -ne 1 ]; then
  echo "A failed update returned $update_status instead of 1" >&2
  exit 1
fi
if [ "$(instance_setting COSMOSYS_REVISION)" != "$target_revision" ]; then
  echo "A failed update left the instance environment file changed" >&2
  exit 1
fi
if [ "$(running_revision)" != "$target_revision" ]; then
  echo "A failed update left the instance on another revision" >&2
  exit 1
fi
instance_runner "
  abort('the seeded user did not survive the failed update') unless
    User.find_by(login: 'update_validation')
"

echo "Checking that an up-to-date instance reports nothing to do..."
update --check --pins "$validation_directory/target.env"

echo "Instance update validation passed."
