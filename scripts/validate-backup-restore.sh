#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

# The stack is configured only through an environment file with non-default
# database names, so backup and restore cannot rely on the shell or defaults.
unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDMINE_SECRET_KEY_BASE \
  COSMOSYS_INITIAL_ADMIN_PASSWORD COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE \
  COSMOSYS_HTTP_PORT COSMOSYS_DB_MODE

validation_directory=$(mktemp -d)
validation_database=csys_validation_database
validation_user=csys_validation_user

export COSMOSYS_VARIANT=base
export COSMOSYS_COMPOSE_PROJECT="csys_backup_validation_$$"
export COSMOSYS_ENV_FILE="$validation_directory/validation.env"

cleanup() {
  deployment_compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$validation_directory"
}
trap cleanup EXIT HUP INT TERM

cat >"$COSMOSYS_ENV_FILE" <<EOF
POSTGRES_DB=$validation_database
POSTGRES_USER=$validation_user
POSTGRES_PASSWORD=validation-database-password-$$
REDMINE_SECRET_KEY_BASE=validation-secret-key-base-$$
COSMOSYS_INITIAL_ADMIN_PASSWORD=validation-admin-password-$$
COSMOSYS_HTTP_PORT=0
EOF

echo "Starting isolated backup/restore validation as $COSMOSYS_COMPOSE_PROJECT..."
deployment_compose up -d --wait --build redmine

expected_revision=$(deployment_compose config | sed -n 's/^ *COSMOSYS_REVISION: *//p' | head -n 1)
test -n "$expected_revision"

deployment_compose exec -T db psql --username "$validation_user" --dbname "$validation_database" \
  --command "CREATE TABLE csys_restore_probe (value text NOT NULL); INSERT INTO csys_restore_probe VALUES ('database-before-backup');" \
  >/dev/null
deployment_compose exec -T redmine sh -c \
  "printf '%s' 'files-before-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

# A promoted revision that is not active yet must not leak into the manifest.
backup_directory=$(COSMOSYS_REVISION=0000000000000000000000000000000000000000 \
  "$deployment_repository_dir/scripts/backup.sh" "$validation_directory")

for manifest_line in \
  "compose_project=$COSMOSYS_COMPOSE_PROJECT" \
  "database=$validation_database" \
  "database_user=$validation_user" \
  "cosmosys_revision=$expected_revision"; do
  if ! grep -qxF "$manifest_line" "$backup_directory/manifest.env"; then
    echo "Backup manifest lacks $manifest_line" >&2
    exit 1
  fi
done
if grep -q '^cosmosys_req_revision=' "$backup_directory/manifest.env"; then
  echo "Base backup manifest names a cosmoSys Req revision" >&2
  exit 1
fi

deployment_compose exec -T db psql --username "$validation_user" --dbname "$validation_database" \
  --command "UPDATE csys_restore_probe SET value = 'database-after-backup';" \
  >/dev/null
deployment_compose exec -T redmine sh -c \
  "printf '%s' 'files-after-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \
  "$deployment_repository_dir/scripts/restore.sh" "$backup_directory" >/dev/null

database_value=$(deployment_compose exec -T db psql --username "$validation_user" --dbname "$validation_database" \
  --tuples-only --no-align --command 'SELECT value FROM csys_restore_probe')
file_value=$(deployment_compose exec -T redmine \
  cat /usr/src/redmine/files/csys-restore-probe.txt)

test "$database_value" = database-before-backup
test "$file_value" = files-before-backup

echo "Backup and restore validation passed."
