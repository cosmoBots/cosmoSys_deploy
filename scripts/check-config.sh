#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root_dir"

test -f .env || {
  echo "Missing .env; copy .env.example and replace its secrets." >&2
  exit 1
}

docker compose -f compose.yml config --quiet
docker compose -f compose.yml -f compose.requirements.yml config --quiet

echo "Both cosmoSys deployment variants have valid Compose configuration."
