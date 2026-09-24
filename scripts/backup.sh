#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

backup_root=${1:-"$deployment_repository_dir/backups"}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
final_directory="$backup_root/$timestamp"
temporary_directory="$backup_root/.${timestamp}.$$"
variant=$(deployment_variant)
database_mode=$(deployment_db_mode)

redmine_container=$(deployment_compose ps -q redmine)
if [ -z "$redmine_container" ]; then
  echo "The redmine service is not running" >&2
  exit 1
fi

# Describe the running container rather than the configuration: an
# environment file may already name revisions that are not active yet.
container_label() {
  label_value=$(docker inspect --format "{{index .Config.Labels \"$1\"}}" "$redmine_container")
  case "$label_value" in
    ''|'<no value>') echo unknown ;;
    *) echo "$label_value" ;;
  esac
}

compose_project=$(container_label com.docker.compose.project)
redmine_image=$(docker inspect --format '{{.Image}}' "$redmine_container")
cosmosys_revision=$(container_label eu.cosmobots.cosmosys.revision)
rspreadsheet_revision=$(container_label eu.cosmobots.rspreadsheet.revision)
cosmosys_req_revision=
if [ "$variant" = requirements ]; then
  cosmosys_req_revision=$(container_label eu.cosmobots.cosmosys-req.revision)
fi

if [ "$cosmosys_revision" = unknown ]; then
  echo "Warning: the running Redmine image has no revision labels; rebuild it to record source revisions." >&2
fi

deployment_read_database_identity

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

deployment_db_client \
  pg_dump --username "$database_user" --dbname "$database_name" --format custom \
  >"$temporary_directory/database.dump"

deployment_compose exec -T redmine \
  tar -C /usr/src/redmine/files -czf - . \
  >"$temporary_directory/files.tar.gz"

{
  echo "format=cosmosys-backup-v1"
  echo "created_at=$timestamp"
  echo "variant=$variant"
  echo "compose_project=$compose_project"
  echo "database_mode=$database_mode"
  echo "database=$database_name"
  echo "database_user=$database_user"
  echo "redmine_image=$redmine_image"
  echo "cosmosys_revision=$cosmosys_revision"
  if [ -n "$cosmosys_req_revision" ]; then
    echo "cosmosys_req_revision=$cosmosys_req_revision"
  fi
  echo "rspreadsheet_revision=$rspreadsheet_revision"
} >"$temporary_directory/manifest.env"

(
  cd "$temporary_directory"
  sha256sum database.dump files.tar.gz manifest.env >SHA256SUMS
)

mv "$temporary_directory" "$final_directory"
trap - EXIT HUP INT TERM
echo "$final_directory"
