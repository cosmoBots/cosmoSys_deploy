#!/bin/sh
set -eu

# Prints the name of the image this deployment builds for a variant, derived
# from its content: the files that end up in the image and the revisions it is
# built from. Any change to them gives another name, so "up to date" can be
# decided by name, and the same content gets the same name on every host. The
# readable prefix keeps the revisions people look up most often.
#
#   scripts/image-tag.sh base
#   scripts/image-tag.sh requirements mathtext
#   scripts/image-tag.sh --ref origin/main requirements

usage() {
  cat >&2 <<EOF
Usage: $0 [--ref REF] base|requirements [TOOL_GROUPS]

Without --ref the name describes this checkout; with it, the commit REF.
TOOL_GROUPS (for example "mathtext") adds the suffix of the last build stage.
EOF
}

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root_dir/scripts/catalog-lib.sh"

ref=
if [ "${1:-}" = --ref ]; then
  if [ "$#" -lt 2 ]; then
    usage
    exit 2
  fi
  ref=$2
  shift 2
fi

variant=${1:-}
tools_setting=${2:-}
case "$variant" in
  base|requirements) ;;
  *)
    usage
    exit 2
    ;;
esac

# Everything the Dockerfile copies into the image, plus the Dockerfile.
inputs='Dockerfile plugins.conf config bootstrap kroki_compat docker scripts/catalog-lib.sh'

if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum | cut -c1-64; }
else
  digest() { shasum -a 256 | cut -c1-64; }
fi

# shellcheck disable=SC2086
if [ -n "$ref" ]; then
  declared=$(git -C "$root_dir" show "$ref:.env.example")
  files=$(git -C "$root_dir" ls-tree -r "$ref" -- $inputs | awk '{ print $3 " " $4 }')
  catalog_text=$(git -C "$root_dir" show "$ref:plugins.conf")
else
  declared=$(cat "$root_dir/.env.example")
  files=$(cd "$root_dir" && git ls-files -- $inputs | while IFS= read -r file; do
    printf '%s %s\n' "$(git hash-object "$file")" "$file"
  done)
  catalog_text=$(cat "$root_dir/plugins.conf")
fi

declared_value() {
  printf '%s\n' "$declared" | sed -n "s/^$1=//p" | tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

redmine_image=$(declared_value REDMINE_IMAGE)
cosmosys_revision=$(declared_value COSMOSYS_REVISION)
rspreadsheet_revision=$(declared_value RSPREADSHEET_REVISION)
req_revision=$(declared_value COSMOSYS_REQ_REVISION)
redmine_version=$(printf '%s\n' "$redmine_image" | sed -n 's/^redmine:\([^@]*\).*/\1/p')

for required in redmine_image cosmosys_revision rspreadsheet_revision redmine_version; do
  eval "required_value=\$$required"
  if [ -z "$required_value" ]; then
    echo "Cannot derive the image name: $required is not declared in .env.example" >&2
    exit 2
  fi
done

catalog_copy=$(mktemp)
trap 'rm -f "$catalog_copy"' EXIT
printf '%s\n' "$catalog_text" >"$catalog_copy"
tools=$(catalog_tools "$catalog_copy" "$tools_setting")
tools=$(printf '%s\n' "$tools" | sed '/^$/d' | catalog_join .)

build_args="REDMINE_IMAGE=$redmine_image
COSMOSYS_REVISION=$cosmosys_revision
RSPREADSHEET_REVISION=$rspreadsheet_revision"
prefix=$(printf '%.7s' "$cosmosys_revision")
repository=cosmobots/cosmosys
if [ "$variant" = requirements ]; then
  if [ -z "$req_revision" ]; then
    echo "Cannot derive the image name: COSMOSYS_REQ_REVISION is not declared in .env.example" >&2
    exit 2
  fi
  build_args="$build_args
COSMOSYS_REQ_REVISION=$req_revision"
  prefix="$prefix-$(printf '%.7s' "$req_revision")"
  repository=cosmobots/cosmosys-req
fi

content=$({ printf '%s\n' "$files" | LC_ALL=C sort -k2; printf '%s\n' "$build_args"; } | digest | cut -c1-12)

printf '%s:%s-%s-redmine-%s%s\n' "$repository" "$prefix" "$content" "$redmine_version" "${tools:+-$tools}"
