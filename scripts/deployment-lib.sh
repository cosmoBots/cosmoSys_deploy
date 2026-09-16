#!/bin/sh

deployment_repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Prints an instance setting such as COSMOSYS_DB_MODE, taken from the shell or
# from the instance environment file. A disagreement between both sources is an
# error rather than a silent choice.
deployment_setting() {
  setting_name=$1
  setting_default=$2
  setting_env_file=${COSMOSYS_ENV_FILE:-"$deployment_repository_dir/.env"}
  setting_from_file=
  if [ -f "$setting_env_file" ]; then
    setting_from_file=$(sed -n "s/^$setting_name=//p" "$setting_env_file" |
      tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//')
  fi
  eval "setting_from_shell=\${$setting_name:-}"
  setting_value=${setting_from_shell:-${setting_from_file:-$setting_default}}

  if [ -n "$setting_from_file" ] && [ "$setting_value" != "$setting_from_file" ]; then
    echo "$setting_name=$setting_value conflicts with $setting_from_file in $setting_env_file" >&2
    return 2
  fi
  printf '%s\n' "$setting_value"
}

# Prints "local" (db service of this project) or "shared" (shared-db server).
deployment_db_mode() {
  db_mode_value=$(deployment_setting COSMOSYS_DB_MODE local) || return

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

# Prints "none" or "shared" (published through the proxy of proxy/).
deployment_proxy_mode() {
  proxy_mode_value=$(deployment_setting COSMOSYS_PROXY_MODE none) || return

  case "$proxy_mode_value" in
    none|shared)
      printf '%s\n' "$proxy_mode_value"
      ;;
    *)
      echo "COSMOSYS_PROXY_MODE must be none or shared" >&2
      return 2
      ;;
  esac
}

deployment_compose() {
  db_mode=$(deployment_db_mode) || return
  proxy_mode=$(deployment_proxy_mode) || return

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

  if [ "$proxy_mode" = shared ]; then
    set -- -f "$deployment_repository_dir/compose.proxy.yml" "$@"
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
