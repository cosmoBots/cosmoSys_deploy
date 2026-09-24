#!/bin/sh
set -eu

# Runs docker compose with the files an instance needs, resolved from its
# environment file: the Requirements overlay, the shared database and the
# shared reverse proxy. Operating an instance therefore never depends on
# remembering a list of -f flags.
#
#   COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/compose.sh up -d
#   COSMOSYS_ENV_FILE=/srv/cosmosys/alpha.env ./scripts/compose.sh logs -f redmine
#
# Without COSMOSYS_ENV_FILE it falls back to .env in the repository, which is
# the single-instance layout of the README.

. "$(dirname -- "$0")/deployment-lib.sh"

deployment_compose "$@"
