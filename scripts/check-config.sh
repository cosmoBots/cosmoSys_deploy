#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"

test -f .env || {
  echo "Missing .env; copy .env.example and replace its secrets." >&2
  exit 1
}

shared_admin_password=${COSMOSYS_DB_ADMIN_PASSWORD:-configuration-check}

docker compose -f compose.yml config --quiet
docker compose -f compose.yml -f compose.requirements.yml config --quiet
docker compose -f compose.yml -f compose.shared-db.yml config --quiet
docker compose -f compose.yml -f compose.requirements.yml -f compose.shared-db.yml config --quiet
COSMOSYS_DB_ADMIN_PASSWORD=$shared_admin_password \
  docker compose -f shared-db/compose.yml config --quiet

# The shared server, the instance database and the backup client must agree.
postgres_images=$(
  {
    docker compose -f compose.yml config --images
    docker compose -f compose.yml -f compose.shared-db.yml --profile tools config --images
    COSMOSYS_DB_ADMIN_PASSWORD=$shared_admin_password \
      docker compose -f shared-db/compose.yml config --images
  } | grep -i postgres | sort -u
)
if [ "$(printf '%s\n' "$postgres_images" | grep -c .)" -ne 1 ]; then
  echo "The PostgreSQL image differs between the instance, its client and the shared server:" >&2
  printf '%s\n' "$postgres_images" >&2
  exit 1
fi

echo "Both cosmoSys deployment variants and the shared PostgreSQL mode have valid Compose configuration."
