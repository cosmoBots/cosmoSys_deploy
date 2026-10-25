#!/bin/sh
set -eu

# Checks the deployment without starting anything: the catalog of optional
# plugins, that every revision is declared consistently, that the image names
# match the content they describe, that Compose accepts every combination
# of variant, database mode, proxy and plugin sets through the wrapper, and
# that the wrapper adds the overlays of an instance after them.

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root_dir/scripts/deployment-lib.sh"
cd "$root_dir"

errors=0
error() {
  echo "$*" >&2
  errors=$((errors + 1))
}

declared() {
  catalog_value "$root_dir/.env.example" "$1"
}

# Prints the default of a Compose interpolation such as ${COSMOSYS_IMAGE:-...}.
compose_default() {
  sed -n "s/.*\${$2:-\([^}]*\)}.*/\1/p" "$1" | head -n 1
}

# The catalog.
catalog=$deployment_catalog
known_tools=" $(catalog_value "$catalog" COSMOSYS_TOOL_GROUPS) "
for option in $(catalog_value "$catalog" COSMOSYS_OPTIONS); do
  case "$option" in
    *[!a-z0-9_]*|'') error "plugins.conf: option '$option' must be lowercase letters, digits and _" ;;
  esac
  if [ -z "$(catalog_value "$catalog" "OPTION_${option}_PLUGINS")" ]; then
    error "plugins.conf: option $option lists no plugins"
  fi
  for tool in $(catalog_value "$catalog" "OPTION_${option}_TOOLS"); do
    case "$known_tools" in
      *" $tool "*) ;;
      *) error "plugins.conf: option $option needs tool group $tool, which COSMOSYS_TOOL_GROUPS does not list" ;;
    esac
  done
  overlay=$(catalog_value "$catalog" "OPTION_${option}_COMPOSE")
  if [ -n "$overlay" ] && [ ! -f "$overlay" ]; then
    error "plugins.conf: option $option adds $overlay, which does not exist"
  fi
  for pin in $(catalog_value "$catalog" "OPTION_${option}_PINS"); do
    if [ -z "$(declared "$pin")" ]; then
      error "plugins.conf: option $option pins $pin, which .env.example does not declare"
    elif [ -n "$overlay" ] && [ "$(compose_default "$overlay" "$pin")" != "$(declared "$pin")" ]; then
      error "$overlay: the default of $pin differs from .env.example"
    fi
  done
done
for tool in $known_tools; do
  python_packages=$(catalog_value "$catalog" "TOOLS_${tool}_PYTHON")
  if [ -z "$(catalog_value "$catalog" "TOOLS_${tool}_APT")$python_packages" ]; then
    error "plugins.conf: tool group $tool lists no packages"
  fi
  [ -n "$python_packages" ] || continue
  lock="docker/python/$tool.txt"
  if [ ! -f "$lock" ]; then
    error "plugins.conf: tool group $tool has no $lock; run scripts/update-pins.sh --python"
    continue
  fi
  for package in $python_packages; do
    normalized=$(printf '%s' "$package" | tr 'A-Z_.' 'a-z--')
    if ! grep -q "^$normalized==" "$lock"; then
      error "$lock does not pin $package; run scripts/update-pins.sh --python"
    fi
  done
done
for plugin in $(catalog_all_plugins "$catalog"); do
  local_dir=$(catalog_value "$catalog" "PLUGIN_${plugin}_LOCAL")
  if [ -n "$local_dir" ]; then
    if [ ! -f "$local_dir/init.rb" ]; then
      error "plugins.conf: local plugin $plugin has no $local_dir/init.rb"
    fi
    if ! grep -q "^COPY $local_dir /opt/cosmosys/plugins-available/$plugin\$" Dockerfile; then
      error "Dockerfile: local plugin $plugin is not copied to /opt/cosmosys/plugins-available/$plugin"
    fi
    continue
  fi
  case "$(catalog_value "$catalog" "PLUGIN_${plugin}_SOURCE")" in
    https://*) ;;
    *) error "plugins.conf: plugin $plugin needs a public HTTPS source" ;;
  esac
  revision=$(catalog_value "$catalog" "PLUGIN_${plugin}_REVISION")
  case "$revision" in
    *[!0-9a-f]*|'') error "plugins.conf: plugin $plugin needs an immutable revision" ;;
    *) [ "${#revision}" -eq 40 ] || error "plugins.conf: plugin $plugin needs a 40-character revision" ;;
  esac
done

# Every revision and image name declared once and consistently.
for setting in REDMINE_IMAGE COSMOSYS_REVISION RSPREADSHEET_REVISION; do
  if [ "$(compose_default compose.yml "$setting")" != "$(declared "$setting")" ]; then
    error "compose.yml: the default of $setting differs from .env.example"
  fi
done
if [ "$(compose_default compose.requirements.yml COSMOSYS_REQ_REVISION)" != "$(declared COSMOSYS_REQ_REVISION)" ]; then
  error "compose.requirements.yml: the default of COSMOSYS_REQ_REVISION differs from .env.example"
fi
expected_image=$(sh scripts/image-tag.sh base)
if [ "$(deployment_declared_image base)" != "$expected_image" ]; then
  error "compose.yml: COSMOSYS_IMAGE should default to $expected_image for this content"
fi
expected_req_image=$(sh scripts/image-tag.sh requirements)
if [ "$(deployment_declared_image requirements)" != "$expected_req_image" ]; then
  error "compose.requirements.yml: COSMOSYS_REQ_IMAGE should default to $expected_req_image for this content"
fi
# The table of the README names every pinned commit.
pins_table=$(sed -n '/^<!-- pins:start -->$/,/^<!-- pins:end -->$/p' README.md)
for revision in "$(declared COSMOSYS_REVISION)" "$(declared COSMOSYS_REQ_REVISION)" "$(declared RSPREADSHEET_REVISION)" \
  $(for plugin in $(catalog_all_plugins "$catalog"); do catalog_value "$catalog" "PLUGIN_${plugin}_REVISION"; done); do
  case "$pins_table" in
    *"\`$(printf '%.7s' "$revision")\`"*) ;;
    *) error "README.md: the pins table does not list $(printf '%.7s' "$revision"); run scripts/update-pins.sh" ;;
  esac
done

untracked=$(git ls-files --others --exclude-standard -- Dockerfile plugins.conf config bootstrap kroki_compat docker scripts/catalog-lib.sh 2>/dev/null || true)
if [ -n "$untracked" ]; then
  echo "Warning: untracked files would end up in the image without changing its name:" >&2
  printf '  %s\n' $untracked >&2
fi

# Every combination, through the wrapper the scripts use. The overlays of a
# host are not part of this repository, so none is taken from the shell.
unset COSMOSYS_COMPOSE_OVERLAYS
check_directory=$(mktemp -d)
trap 'rm -rf "$check_directory"' EXIT
all_options=$(catalog_value "$catalog" COSMOSYS_OPTIONS | tr ' ' ',')
all_tools=$(catalog_option_tools "$catalog" "$(catalog_value "$catalog" COSMOSYS_OPTIONS)" | catalog_join ,)
combinations=0
for variant in base requirements; do
  for db_mode in local shared; do
    for proxy_mode in none shared; do
      for plugins in '' "$all_options"; do
        tools=
        if [ -n "$plugins" ]; then
          tools=$all_tools
        fi
        env_file="$check_directory/$variant-$db_mode-$proxy_mode-${plugins:-none}.env"
        cat >"$env_file" <<EOF
POSTGRES_PASSWORD=configuration-check
REDMINE_SECRET_KEY_BASE=configuration-check
COSMOSYS_VARIANT=$variant
COSMOSYS_DB_MODE=$db_mode
COSMOSYS_PROXY_MODE=$proxy_mode
COSMOSYS_HOSTNAME=csys.example.org
COSMOSYS_PROXY_TLS=internal
COSMOSYS_PLUGINS=$plugins
COSMOSYS_TOOLS=$tools
EOF
        if ! COSMOSYS_ENV_FILE=$env_file deployment_compose config --quiet; then
          error "Compose rejects $variant, $db_mode database, proxy $proxy_mode, plugin sets ${plugins:-none}"
        fi
        combinations=$((combinations + 1))
      done
    done
  done
done

# The overlays of an instance: found next to its environment file or by
# absolute path, added after every file of this repository and in the order
# listed, and refused when one is missing.
mkdir "$check_directory/overlays"
cat >"$check_directory/overlays/first.yml" <<'EOF'
services:
  redmine:
    labels:
      caddy.tls: overlay-check
      eu.cosmobots.check.first: kept
      eu.cosmobots.check.order: first
EOF
cat >"$check_directory/second.yml" <<'EOF'
services:
  redmine:
    labels:
      eu.cosmobots.check.order: second
EOF
{
  cat "$check_directory/base-local-shared-none.env"
  echo "COSMOSYS_COMPOSE_OVERLAYS=overlays/first.yml, $check_directory/second.yml"
} >"$check_directory/overlays.env"
if ! overlays_config=$(COSMOSYS_ENV_FILE="$check_directory/overlays.env" deployment_compose config); then
  error "Compose rejects an instance with overlays"
else
  for overlays_label in 'caddy.tls: overlay-check' 'eu.cosmobots.check.first: kept' \
    'eu.cosmobots.check.order: second'; do
    case "$overlays_config" in
      *"$overlays_label"*) ;;
      *) error "The overlays of an instance do not apply in order: '$overlays_label' is missing" ;;
    esac
  done
fi
echo "COSMOSYS_COMPOSE_OVERLAYS=overlays/missing.yml" >"$check_directory/missing-overlay.env"
overlays_status=0
COSMOSYS_ENV_FILE="$check_directory/missing-overlay.env" deployment_compose config --quiet \
  >/dev/null 2>&1 || overlays_status=$?
if [ "$overlays_status" -ne 2 ]; then
  error "An instance naming a missing overlay returned $overlays_status instead of 2"
fi

COSMOSYS_DB_ADMIN_PASSWORD=${COSMOSYS_DB_ADMIN_PASSWORD:-configuration-check} \
  docker compose -f shared-db/compose.yml config --quiet
docker compose -f proxy/compose.yml config --quiet

# The shared server, the instance database and the backup client must agree.
postgres_images=$(
  {
    COSMOSYS_ENV_FILE="$check_directory/base-shared-none-none.env" deployment_compose --profile tools config --images
    COSMOSYS_ENV_FILE="$check_directory/base-local-none-none.env" deployment_compose config --images
    COSMOSYS_DB_ADMIN_PASSWORD=configuration-check \
      docker compose -f shared-db/compose.yml config --images
  } | grep -i postgres | sort -u
)
if [ "$(printf '%s\n' "$postgres_images" | grep -c .)" -ne 1 ]; then
  error "The PostgreSQL image differs between the instance, its client and the shared server:"
  printf '%s\n' "$postgres_images" >&2
fi

if [ "$errors" -ne 0 ]; then
  echo "$errors configuration problems found." >&2
  exit 1
fi
echo "The catalog, the declared revisions and image names, and $combinations Compose combinations are valid."
