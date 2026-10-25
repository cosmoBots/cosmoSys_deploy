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

# Prints "base" or "requirements" (the variant that adds cosmoSys Requirements).
deployment_variant() {
  variant_value=$(deployment_setting COSMOSYS_VARIANT base) || return

  case "$variant_value" in
    base|requirements)
      printf '%s\n' "$variant_value"
      ;;
    *)
      echo "COSMOSYS_VARIANT must be base or requirements" >&2
      return 2
      ;;
  esac
}

deployment_catalog="$deployment_repository_dir/plugins.conf"
. "$deployment_repository_dir/scripts/catalog-lib.sh"

# Prints the optional plugin sets of plugins.conf that the instance activates
# (COSMOSYS_PLUGINS), one per line. Before plugins.conf, Kroki, LaTeX, the
# notebook preview and PORIS had a switch each; an instance file that still
# turns one on has to say it with COSMOSYS_PLUGINS instead, because those
# switches also chose images that no longer exist.
deployment_plugins() {
  for legacy_setting in COSMOSYS_KROKI_ENABLED COSMOSYS_LATEX_ENABLED \
    COSMOSYS_NOTEBOOK_PREVIEW_ENABLED COSMOSYS_PORIS_ENABLED; do
    legacy_value=$(deployment_setting "$legacy_setting" false) || return
    if [ "$legacy_value" = true ]; then
      echo "$legacy_setting=true belongs to the previous way of enabling optional plugins." >&2
      echo "List the set in COSMOSYS_PLUGINS instead (kroki, latex, notebooks, poris) and remove the old" >&2
      echo "switches, then run scripts/update-instance.sh to rebuild the instance." >&2
      return 2
    fi
  done

  plugins_value=$(deployment_setting COSMOSYS_PLUGINS '') || return
  catalog_options "$deployment_catalog" "$plugins_value"
}

# Prints the tool groups the image of the instance has to include for its
# plugin sets, one per line.
deployment_tools() {
  tools_plugins=$(deployment_plugins) || return
  catalog_option_tools "$deployment_catalog" "$tools_plugins"
}

# Checks that COSMOSYS_TOOLS, the build argument of the last stage, provides
# the tools of the plugin sets, so that Compose never builds an image whose
# entrypoint will refuse the instance.
deployment_check_tools() {
  required_tools=$(deployment_tools) || return
  required_tools=$(printf '%s\n' "$required_tools" | catalog_join ' ')
  declared_tools_value=$(deployment_setting COSMOSYS_TOOLS '') || return
  declared_tools=$(catalog_tools "$deployment_catalog" "$declared_tools_value") || return
  declared_tools=$(printf '%s\n' "$declared_tools" | catalog_join ' ')
  if [ "$required_tools" != "$declared_tools" ]; then
    echo "COSMOSYS_TOOLS=${declared_tools_value} does not match the tools of COSMOSYS_PLUGINS (${required_tools:-none})." >&2
    echo "Change the plugin sets of an instance with scripts/update-instance.sh --plugins." >&2
    return 2
  fi
}

# Prints the image name that compose.yml (base) or compose.requirements.yml
# (requirements) declares by default, in this checkout or at git reference REF.
deployment_declared_image() {
  if [ "$1" = requirements ]; then
    image_file=compose.requirements.yml
    image_key=COSMOSYS_REQ_IMAGE
  else
    image_file=compose.yml
    image_key=COSMOSYS_IMAGE
  fi
  if [ -n "${2:-}" ]; then
    image_text=$(git -C "$deployment_repository_dir" show "$2:$image_file") || return
  else
    image_text=$(cat "$deployment_repository_dir/$image_file")
  fi
  printf '%s\n' "$image_text" | sed -n "s/.*\${$image_key:-\([^}]*\)}.*/\1/p" | head -n 1
}

# Prints IMAGE with the suffix the last build stage adds for TOOL_GROUPS, the
# convention of scripts/image-tag.sh.
deployment_image_with_tools() {
  image_tools=$(catalog_tools "$deployment_catalog" "${2:-}") || return
  image_tools=$(printf '%s\n' "$image_tools" | sed '/^$/d' | catalog_join .)
  printf '%s%s\n' "$1" "${image_tools:+-$image_tools}"
}

# Prints a label of a container, or "unknown" when the image predates it.
deployment_container_label() {
  label_value=$(docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1")
  case "$label_value" in
    ''|'<no value>')
      printf 'unknown\n'
      ;;
    *)
      printf '%s\n' "$label_value"
      ;;
  esac
}

# Prints the Compose files of the host that the instance adds to the ones of
# this repository (COSMOSYS_COMPOSE_OVERLAYS, separated by commas), one per
# line and in order. They belong to whoever runs the host, such as a block of
# address ranges at the reverse proxy, and never to this repository. A relative
# path is taken from the directory of the instance environment file. A file
# that does not exist is an error, so that an instance never starts without
# something its environment file asks for.
deployment_overlays() {
  overlays_value=$(deployment_setting COSMOSYS_COMPOSE_OVERLAYS '') || return
  [ -n "$overlays_value" ] || return 0
  overlays_env_file=${COSMOSYS_ENV_FILE:-"$deployment_repository_dir/.env"}
  overlays_directory=$(CDPATH= cd -- "$(dirname -- "$overlays_env_file")" && pwd) || return
  overlays_list=$(printf '%s\n' "$overlays_value" | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

  while IFS= read -r overlays_entry; do
    [ -n "$overlays_entry" ] || continue
    case "$overlays_entry" in
      /*) ;;
      *) overlays_entry="$overlays_directory/$overlays_entry" ;;
    esac
    if [ ! -f "$overlays_entry" ]; then
      echo "COSMOSYS_COMPOSE_OVERLAYS names $overlays_entry, which does not exist" >&2
      return 2
    fi
    printf '%s\n' "$overlays_entry"
  done <<EOF
$overlays_list
EOF
}

deployment_compose() {
  db_mode=$(deployment_db_mode) || return
  proxy_mode=$(deployment_proxy_mode) || return
  variant=$(deployment_variant) || return
  compose_plugins=$(deployment_plugins) || return
  compose_instance_overlays=$(deployment_overlays) || return

  # Commands that build or start containers need an image with the tools of
  # the plugin sets; reading the state of an instance does not.
  for compose_argument in "$@"; do
    case "$compose_argument" in
      -*) ;;
      up|build|run|create|start|restart)
        deployment_check_tools || return
        break
        ;;
      *) break ;;
    esac
  done

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

  # The overlays of the instance come last, so that they can change anything
  # the files of this repository declare, and in the order the instance lists
  # them. Arguments are prepended, so they are added from the last one.
  while IFS= read -r compose_overlay; do
    [ -n "$compose_overlay" ] || continue
    set -- -f "$compose_overlay" "$@"
  done <<EOF
$(printf '%s\n' "$compose_instance_overlays" | sed '1!G;h;$!d')
EOF

  # Only compose.requirements.yml changes the image; the overlays of the
  # plugin sets only add services, so their order does not matter. Arguments
  # are prepended, so the last one added comes first.
  for compose_overlay in $(catalog_option_compose_files "$deployment_catalog" "$compose_plugins" | sort -r); do
    set -- -f "$deployment_repository_dir/$compose_overlay" "$@"
  done

  if [ "$proxy_mode" = shared ]; then
    set -- -f "$deployment_repository_dir/compose.proxy.yml" "$@"
  fi

  if [ "$db_mode" = shared ]; then
    set -- -f "$deployment_repository_dir/compose.shared-db.yml" "$@"
  fi

  if [ "$variant" = requirements ]; then
    set -- -f "$deployment_repository_dir/compose.requirements.yml" "$@"
  fi

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
