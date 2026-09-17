#!/bin/sh

deployment_repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Prints "local" (db service of this project) or "shared" (shared-db server).
# COSMOSYS_DB_MODE comes from the shell or from the instance environment file;
# a disagreement between both is an error rather than a silent choice.
deployment_db_mode() {
  db_mode_env_file=${COSMOSYS_ENV_FILE:-"$deployment_repository_dir/.env"}
  db_mode_from_file=
  if [ -f "$db_mode_env_file" ]; then
    db_mode_from_file=$(sed -n 's/^COSMOSYS_DB_MODE=//p' "$db_mode_env_file" |
      tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//')
  fi
  db_mode_value=${COSMOSYS_DB_MODE:-${db_mode_from_file:-local}}

  if [ -n "$db_mode_from_file" ] && [ "$db_mode_value" != "$db_mode_from_file" ]; then
    echo "COSMOSYS_DB_MODE=$db_mode_value conflicts with $db_mode_from_file in $db_mode_env_file" >&2
    return 2
  fi

  case "$db_mode_value" in
    local|shared)
      printf '%s\n' "$db_mode_value"
      ;;
    *)
      echo "COSMOSYS_DB_MODE must be local or shared" >&2
      return 2
      ;;
  esac
}

deployment_compose() {
  db_mode=$(deployment_db_mode) || return

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

  if [ "$db_mode" = shared ]; then
    set -- -f "$deployment_repository_dir/compose.shared-db.yml" "$@"
  fi

  case "${COSMOSYS_VARIANT:-base}" in
    base)
      ;;
    requirements)
      set -- -f "$deployment_repository_dir/compose.requirements.yml" "$@"
      ;;
    *)
      echo "COSMOSYS_VARIANT must be base or requirements" >&2
      return 2
      ;;
  esac

  docker compose -f "$deployment_repository_dir/compose.yml" "$@"
}

# Runs a PostgreSQL client command against the instance database.
deployment_db_client() {
  db_mode=$(deployment_db_mode) || return

  if [ "$db_mode" = shared ]; then
    deployment_compose run --rm --no-deps -T db-client "$@"
  else
    deployment_compose exec -T db "$@"
  fi
}

deployment_read_database_identity() {
  database_name=$(deployment_db_client sh -c 'printf %s "${POSTGRES_DB:-$PGDATABASE}"')
  database_user=$(deployment_db_client sh -c 'printf %s "${POSTGRES_USER:-$PGUSER}"')

  if [ -z "$database_name" ] || [ -z "$database_user" ]; then
    echo "Cannot read the database name and user of this instance" >&2
    return 1
  fi
}
