#!/bin/sh

deployment_repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

deployment_compose() {
  if [ -n "${COSMOSYS_COMPOSE_PROJECT:-}" ]; then
    set -- -p "$COSMOSYS_COMPOSE_PROJECT" "$@"
  fi

  if [ -n "${COSMOSYS_ENV_FILE:-}" ]; then
    if [ ! -f "$COSMOSYS_ENV_FILE" ]; then
      echo "COSMOSYS_ENV_FILE does not exist: $COSMOSYS_ENV_FILE" >&2
      return 2
    fi
    set -- --env-file "$COSMOSYS_ENV_FILE" "$@"
  fi

  case "${COSMOSYS_VARIANT:-base}" in
    base)
      docker compose -f "$deployment_repository_dir/compose.yml" "$@"
      ;;
    requirements)
      docker compose -f "$deployment_repository_dir/compose.yml" \
        -f "$deployment_repository_dir/compose.requirements.yml" "$@"
      ;;
    *)
      echo "COSMOSYS_VARIANT must be base or requirements" >&2
      return 2
      ;;
  esac
}

deployment_read_database_identity() {
  database_name=$(deployment_compose exec -T db sh -c 'printf %s "$POSTGRES_DB"')
  database_user=$(deployment_compose exec -T db sh -c 'printf %s "$POSTGRES_USER"')

  if [ -z "$database_name" ] || [ -z "$database_user" ]; then
    echo "Cannot read POSTGRES_DB and POSTGRES_USER from the db service" >&2
    return 1
  fi
}
