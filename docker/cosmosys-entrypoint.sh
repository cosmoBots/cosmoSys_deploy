#!/bin/sh
set -eu

# Runs before the entrypoint of the official Redmine image in every service of
# the image (migrate, bootstrap and redmine). It copies into plugins/ the
# optional plugins of the options listed in COSMOSYS_PLUGINS and leaves the
# rest where Redmine never looks, then hands over to the official entrypoint.
# An option this image does not know, or whose tools it lacks, stops the
# container instead of starting Redmine without it.

deploy_dir=/opt/cosmosys-deploy
catalog="$deploy_dir/plugins.conf"
available=/opt/cosmosys/plugins-available
plugins_dir=/usr/src/redmine/plugins

. "$deploy_dir/catalog-lib.sh"

fail() {
  echo "cosmoSys: $*" >&2
  exit 64
}

options=$(catalog_options "$catalog" "${COSMOSYS_PLUGINS:-}") ||
  fail "COSMOSYS_PLUGINS=${COSMOSYS_PLUGINS:-} names a set this image does not offer"

installed_tools=$(cat "$deploy_dir/tools" 2>/dev/null || true)
for tool in $(catalog_option_tools "$catalog" "$options"); do
  case " $(printf '%s ' $installed_tools)" in
    *" $tool "*) ;;
    *) fail "the plugins in COSMOSYS_PLUGINS need the tool group $tool, which this image was built without; build it with COSMOSYS_TOOLS listing $tool" ;;
  esac
done

# Plugins are copied rather than linked: plugins require their own files
# through __dir__, which resolves links, so a linked plugin would be loaded
# twice, once under each path. A container that restarts keeps its copies.
active_plugins=$(catalog_option_plugins "$catalog" "$options")
for plugin in $active_plugins; do
  copy="$plugins_dir/$plugin"
  if [ -f "$copy/.cosmosys-optional-plugin" ]; then
    continue
  elif [ -e "$copy" ]; then
    fail "$copy already exists and is not an optional plugin of this image"
  fi
  cp -a "$available/$plugin" "$copy.partial"
  : >"$copy.partial/.cosmosys-optional-plugin"
  mv "$copy.partial" "$copy"
done

# Read by config/additional_environment.rb, also in processes started with
# docker exec, which do not go through this entrypoint.
printf '%s\n' $active_plugins >"$deploy_dir/active-plugins"

exec "$@"
