#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

backup_directory=${1:-}

if [ -z "$backup_directory" ]; then
  echo "Usage: RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA $0 BACKUP_DIRECTORY" >&2
  exit 2
fi

if [ "${RESTORE_CONFIRMATION:-}" != ERASE_EXISTING_COSMOSYS_DATA ]; then
  echo "Restore replaces the current database and files." >&2
  echo "Set RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA to continue." >&2
  exit 2
fi

for required_file in database.dump files.tar.gz manifest.env SHA256SUMS; do
  if [ ! -f "$backup_directory/$required_file" ]; then
    echo "Incomplete backup: missing $required_file" >&2
    exit 1
  fi
done

if ! grep -qx 'format=cosmosys-backup-v1' "$backup_directory/manifest.env"; then
  echo "Unsupported backup format" >&2
  exit 1
fi

(
  cd "$backup_directory"
  sha256sum --check SHA256SUMS
)

database_mode=$(deployment_db_mode)
deployment_read_database_identity

deployment_compose stop redmine >/dev/null

if [ "$database_mode" = shared ]; then
  # A shared-server role owns its database but may not recreate it, so it
  # removes the objects it owns instead.
  deployment_db_client \
    psql --username "$database_user" --dbname "$database_name" \
    --set ON_ERROR_STOP=1 --quiet --command 'DROP OWNED BY CURRENT_USER'
else
  deployment_db_client \
    dropdb --username "$database_user" --if-exists --force "$database_name"
  deployment_db_client \
    createdb --username "$database_user" --owner "$database_user" "$database_name"
fi
# Restored objects belong to this instance's database user, even when the
# backup comes from an instance that uses another one.
deployment_db_client \
  pg_restore --username "$database_user" --dbname "$database_name" --no-owner \
  <"$backup_directory/database.dump"

deployment_compose run --rm --no-deps --entrypoint sh redmine \
  -c 'find /usr/src/redmine/files -mindepth 1 -delete'
deployment_compose run --rm --no-deps --entrypoint tar redmine \
  -C /usr/src/redmine/files -xzf - \
  <"$backup_directory/files.tar.gz"

deployment_compose up -d --wait redmine
echo "Restore completed from $backup_directory"
