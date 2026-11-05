#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root_dir/scripts/catalog-lib.sh"
catalog="$root_dir/plugins.conf"
for option in arch poris_arch; do
  if catalog_check_variant "$catalog" "$option" base >/dev/null 2>&1; then
    echo "$option incorrectly accepted base" >&2
    exit 1
  fi
  catalog_check_variant "$catalog" "$option" requirements
  tools=$(catalog_option_tools "$catalog" "$option")
  test "$tools" = libredwg
done
plugins=$(catalog_option_plugins "$catalog" 'arch cad poris poris_arch')
test "$(printf '%s\n' "$plugins" | sort | uniq -d | wc -l)" -eq 0
for plugin in redmine_cad_preview cosmosys_cad_preview cosmosys_poris cosmosys_arch cosmosys_poris_arch; do
  printf '%s\n' "$plugins" | grep -qx "$plugin"
done
test "$(catalog_plugin_directory "$catalog" cosmosys_arch)" = cosmosys_zarch
test "$(catalog_plugin_directory "$catalog" cosmosys_poris_arch)" = cosmosys_zzporis_arch
test "$(catalog_plugin_directory "$catalog" cosmosys_poris)" = cosmosys_poris
echo 'Architecture catalog: PASS (dependencies, deduplication, tools, variants, runtime directories)'
