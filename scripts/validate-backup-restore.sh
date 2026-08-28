#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

export COSMOSYS_VARIANT=base
export COSMOSYS_COMPOSE_PROJECT="csys_backup_validation_$$"
export POSTGRES_PASSWORD="validation-database-password-$$"
export REDMINE_SECRET_KEY_BASE="validation-secret-key-base-$$"
export COSMOSYS_HTTP_PORT=0

validation_directory=$(mktemp -d)

cleanup() {
  deployment_compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$validation_directory"
}
trap cleanup EXIT HUP INT TERM

echo "Starting isolated backup/restore validation as $COSMOSYS_COMPOSE_PROJECT..."
deployment_compose up -d --wait redmine

deployment_compose exec -T db psql --username redmine --dbname redmine \
  --command "CREATE TABLE csys_restore_probe (value text NOT NULL); INSERT INTO csys_restore_probe VALUES ('database-before-backup');" \
  >/dev/null
deployment_compose exec -T redmine sh -c \
  "printf '%s' 'files-before-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

backup_directory=$("$deployment_repository_dir/scripts/backup.sh" "$validation_directory")

deployment_compose exec -T db psql --username redmine --dbname redmine \
  --command "UPDATE csys_restore_probe SET value = 'database-after-backup';" \
  >/dev/null
deployment_compose exec -T redmine sh -c \
  "printf '%s' 'files-after-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \
  "$deployment_repository_dir/scripts/restore.sh" "$backup_directory" >/dev/null

database_value=$(deployment_compose exec -T db psql --username redmine --dbname redmine \
  --tuples-only --no-align --command 'SELECT value FROM csys_restore_probe')
file_value=$(deployment_compose exec -T redmine \
  cat /usr/src/redmine/files/csys-restore-probe.txt)

test "$database_value" = database-before-backup
test "$file_value" = files-before-backup

echo "Backup and restore validation passed."
