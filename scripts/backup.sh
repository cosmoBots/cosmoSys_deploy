#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

backup_root=${1:-"$deployment_repository_dir/backups"}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
final_directory="$backup_root/$timestamp"
temporary_directory="$backup_root/.${timestamp}.$$"
database_name=${POSTGRES_DB:-redmine}
database_user=${POSTGRES_USER:-redmine}

mkdir -p "$backup_root"
if [ -e "$final_directory" ]; then
  echo "Backup target already exists: $final_directory" >&2
  exit 1
fi
mkdir "$temporary_directory"

cleanup() {
  if [ -d "$temporary_directory" ]; then
    rm -rf -- "$temporary_directory"
  fi
}
trap cleanup EXIT HUP INT TERM

deployment_compose exec -T db \
  pg_dump --username "$database_user" --dbname "$database_name" --format custom \
  >"$temporary_directory/database.dump"

deployment_compose exec -T redmine \
  tar -C /usr/src/redmine/files -czf - . \
  >"$temporary_directory/files.tar.gz"

{
  echo "format=cosmosys-backup-v1"
  echo "created_at=$timestamp"
  echo "variant=${COSMOSYS_VARIANT:-base}"
  echo "database=$database_name"
  echo "database_user=$database_user"
  echo "cosmosys_revision=${COSMOSYS_REVISION:-1d940430da077fb408dcbc14e94337ce9b9da288}"
  echo "cosmosys_req_revision=${COSMOSYS_REQ_REVISION:-31f9aaf527c258b127c3e429c36b3a4c9e411b29}"
  echo "rspreadsheet_revision=${RSPREADSHEET_REVISION:-c01d413abc728db9d62aa1bebe776f548ee69999}"
} >"$temporary_directory/manifest.env"

(
  cd "$temporary_directory"
  sha256sum database.dump files.tar.gz manifest.env >SHA256SUMS
)

mv "$temporary_directory" "$final_directory"
trap - EXIT HUP INT TERM
echo "$final_directory"
