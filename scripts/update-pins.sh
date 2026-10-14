#!/bin/sh
set -eu

# Moves the pinned revisions of the deployment and rewrites everything that
# derives from them, so that a pin is never edited by hand in one place and
# forgotten in another:
#
#   .env.example               COSMOSYS_REVISION, COSMOSYS_REQ_REVISION and
#                              RSPREADSHEET_REVISION
#   compose.yml and            the same revisions as Compose defaults, and the
#   compose.requirements.yml   image names scripts/image-tag.sh derives
#   plugins.conf               the revisions of the optional plugins
#   docker/python/<group>.txt  the Python packages of the tool groups
#   README.md                  the table of current pins
#
# Revisions only move forward unless --allow-backwards is given, and cosmoSys
# Requirements and the optional plugins have to accept the cosmoSys version
# they are pinned with. Nothing is committed; the script ends by running
# scripts/check-config.sh.
#
#   scripts/update-pins.sh --cosmosys 0.1.7 --cosmosys-req 0.3.2
#   scripts/update-pins.sh --plugin redmine_cbots_latex=main
#   scripts/update-pins.sh --latest-tags --summary pins.md
#   scripts/update-pins.sh --python

usage() {
  cat >&2 <<EOF
Usage: $0 [--cosmosys REF] [--cosmosys-req REF] [--rspreadsheet REF]
          [--plugin PLUGIN=REF]... [--latest-tags] [--python]
          [--allow-backwards] [--summary FILE] [--no-check]

REF is a tag, a branch or a commit of the component's repository; the pin is
always the full commit. --latest-tags pins cosmoSys and cosmoSys Requirements
to their highest X.Y.Z tags. --python resolves the Python packages of the tool
groups again, to their latest versions, inside the Redmine image (needs
Docker). --summary writes a Markdown summary of the changes, for a pull
request. With no option the script only rewrites what derives from the
current pins.
EOF
}

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root_dir/scripts/catalog-lib.sh"
catalog="$root_dir/plugins.conf"
environment="$root_dir/.env.example"

# The repositories the Dockerfile clones the cosmoSys plugins from.
cosmosys_url=https://github.com/cosmoBots/cosmoSys.git
cosmosys_req_url=https://github.com/cosmoBots/cosmoSys_Req.git
rspreadsheet_url=https://github.com/cosmoBots/rspreadsheet.git

# The pip-tools release that resolves the Python packages.
pip_tools_version=7.6.2

cosmosys_ref=
cosmosys_req_ref=
rspreadsheet_ref=
plugin_requests=
latest_tags=0
python=0
allow_backwards=0
summary_file=
run_check=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cosmosys|--cosmosys-req|--rspreadsheet|--plugin|--summary)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      case "$1" in
        --cosmosys) cosmosys_ref=$2 ;;
        --cosmosys-req) cosmosys_req_ref=$2 ;;
        --rspreadsheet) rspreadsheet_ref=$2 ;;
        --plugin) plugin_requests="$plugin_requests $2" ;;
        --summary) summary_file=$2 ;;
      esac
      shift 2
      ;;
    --latest-tags) latest_tags=1; shift ;;
    --python) python=1; shift ;;
    --allow-backwards) allow_backwards=1; shift ;;
    --no-check) run_check=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

known_plugins=" $(catalog_all_plugins "$catalog" | catalog_join ' ') "
for request in $plugin_requests; do
  plugin=${request%%=*}
  case "$request" in
    *=?*) ;;
    *) echo "--plugin takes PLUGIN=REF, not $request" >&2; exit 2 ;;
  esac
  case "$known_plugins" in
    *" $plugin "*) ;;
    *) echo "plugins.conf declares no optional plugin $plugin" >&2; exit 2 ;;
  esac
  if [ -n "$(catalog_value "$catalog" "PLUGIN_${plugin}_LOCAL")" ]; then
    echo "$plugin lives in this repository and has no revision to pin" >&2
    exit 2
  fi
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
: >"$work_dir/changes"

short() {
  printf '%.7s' "$1"
}

# Prints the path of a bare clone of URL with its commits and trees but no file
# contents; git fetches the few files read here when they are first read.
repository() {
  repository_path="$work_dir/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -d "$repository_path" ]; then
    git clone --quiet --bare --filter=blob:none "$1" "$repository_path" >&2
  fi
  printf '%s\n' "$repository_path"
}

# Prints the full commit of REF, a tag, a branch or a commit of URL.
resolve() {
  resolve_repository=$(repository "$1") || return
  if ! git -C "$resolve_repository" rev-parse --verify --quiet "$2^{commit}"; then
    echo "$2 is not a tag, branch or commit of $1" >&2
    return 2
  fi
}

# Sorts X.Y.Z versions, lowest first.
sort_versions() {
  sort -t. -k1,1n -k2,2n -k3,3n
}

# Prints the highest X.Y.Z tag of URL.
latest_tag() {
  latest_repository=$(repository "$1") || return
  git -C "$latest_repository" tag --list | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort_versions | tail -n 1
}

# Prints the tag of COMMIT in URL, "after TAG" for the closest tag it
# contains, or "none".
describe_tag() {
  describe_repository=$(repository "$1") || return
  describe_exact=$(git -C "$describe_repository" tag --points-at "$2" | sort_versions | tail -n 1)
  if [ -n "$describe_exact" ]; then
    printf '`%s`\n' "$describe_exact"
  elif describe_closest=$(git -C "$describe_repository" describe --tags --abbrev=0 "$2" 2>/dev/null); then
    printf 'after `%s`\n' "$describe_closest"
  else
    printf 'none\n'
  fi
}

# Prints the version a Redmine plugin declares at COMMIT of URL: the literal
# in init.rb or, when init.rb names a constant, the VERSION of lib/ID/version.rb
# or lib/ID.rb. DIR is the directory of the repository that is the plugin.
plugin_version() {
  version_repository=$(repository "$1") || return
  version_prefix=${3:+$3/}
  version=$(git -C "$version_repository" show "$2:${version_prefix}init.rb" 2>/dev/null |
    sed -n "s/^[[:space:]]*version[[:space:](]*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
  for version_file in "lib/$4/version.rb" "lib/$4.rb"; do
    [ -z "$version" ] || break
    version=$(git -C "$version_repository" show "$2:$version_prefix$version_file" 2>/dev/null |
      sed -n "s/.*VERSION[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
  done
  printf '%s\n' "${version:-n/a}"
}

# Records the move of NAME from OLD to NEW in URL, refusing to go backwards.
record_move() {
  move_name=$1
  move_url=$2
  move_old=$3
  move_new=$4
  [ "$move_old" != "$move_new" ] || return 0
  move_repository=$(repository "$move_url") || return
  if ! git -C "$move_repository" merge-base --is-ancestor "$move_old" "$move_new" 2>/dev/null; then
    if [ "$allow_backwards" = 0 ]; then
      echo "$move_name would move from $(short "$move_old") to $(short "$move_new"), which does not contain it." >&2
      echo "Pass --allow-backwards if that is intended." >&2
      return 3
    fi
    echo "Warning: $move_name moves from $(short "$move_old") to $(short "$move_new"), which does not contain it." >&2
  fi
  printf '%s|%s|%s|%s\n' "$move_name" "$move_url" "$move_old" "$move_new" >>"$work_dir/changes"
}

# Rewrites FILE through standard input, keeping its permissions.
replace_file() {
  cat >"$work_dir/replacement"
  cat "$work_dir/replacement" >"$1"
}

# Sets KEY=VALUE in an environment-style FILE.
set_setting() {
  awk -v key="$2" -v value="$3" '
    index($0, key "=") == 1 { $0 = key "=" value; found = 1 }
    { print }
    END { exit !found }
  ' "$1" | replace_file "$1"
}

# Sets the default of ${KEY:-...} in a Compose FILE.
set_compose_default() {
  awk -v key="$2" -v value="$3" '
    {
      marker = "${" key ":-"
      start = index($0, marker)
      if (start) {
        rest = substr($0, start + length(marker))
        $0 = substr($0, 1, start + length(marker) - 1) value substr(rest, index(rest, "}"))
        found = 1
      }
      print
    }
    END { exit !found }
  ' "$1" | replace_file "$1"
}

# cosmoSys, cosmoSys Requirements and rspreadsheet.
if [ "$latest_tags" = 1 ]; then
  cosmosys_ref=${cosmosys_ref:-$(latest_tag "$cosmosys_url")}
  cosmosys_req_ref=${cosmosys_req_ref:-$(latest_tag "$cosmosys_req_url")}
fi
cosmosys_old=$(catalog_value "$environment" COSMOSYS_REVISION)
cosmosys_req_old=$(catalog_value "$environment" COSMOSYS_REQ_REVISION)
rspreadsheet_old=$(catalog_value "$environment" RSPREADSHEET_REVISION)
cosmosys_new=$cosmosys_old
cosmosys_req_new=$cosmosys_req_old
rspreadsheet_new=$rspreadsheet_old
if [ -n "$cosmosys_ref" ]; then
  cosmosys_new=$(resolve "$cosmosys_url" "$cosmosys_ref")
  record_move cosmoSys "$cosmosys_url" "$cosmosys_old" "$cosmosys_new"
fi
if [ -n "$cosmosys_req_ref" ]; then
  cosmosys_req_new=$(resolve "$cosmosys_req_url" "$cosmosys_req_ref")
  record_move "cosmoSys Requirements" "$cosmosys_req_url" "$cosmosys_req_old" "$cosmosys_req_new"
fi
if [ -n "$rspreadsheet_ref" ]; then
  rspreadsheet_new=$(resolve "$rspreadsheet_url" "$rspreadsheet_ref")
  record_move rspreadsheet "$rspreadsheet_url" "$rspreadsheet_old" "$rspreadsheet_new"
fi

# Optional plugins.
plugin_moves=
for request in $plugin_requests; do
  plugin=${request%%=*}
  plugin_url=$(catalog_value "$catalog" "PLUGIN_${plugin}_SOURCE")
  plugin_old=$(catalog_value "$catalog" "PLUGIN_${plugin}_REVISION")
  plugin_new=$(resolve "$plugin_url" "${request#*=}")
  record_move "$plugin" "$plugin_url" "$plugin_old" "$plugin_new"
  plugin_moves="$plugin_moves $plugin=$plugin_new"
done

# cosmoSys Requirements and some optional plugins declare the lowest cosmoSys
# version they run on; checked before anything is written (NAME URL COMMIT DIR).
cosmosys_version=$(plugin_version "$cosmosys_url" "$cosmosys_new" '' cosmosys)
check_cosmosys_requirement() {
  required_cosmosys=$(git -C "$(repository "$2")" show "$3:${4:+$4/}init.rb" |
    sed -n "s/.*requires_redmine_plugin[[:space:](]*:cosmosys,[[:space:]]*version_or_higher:[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" | head -n 1)
  if [ -n "$required_cosmosys" ] &&
    [ "$(printf '%s\n%s\n' "$required_cosmosys" "$cosmosys_version" | sort_versions | head -n 1)" != "$required_cosmosys" ]; then
    echo "$1 $(short "$3") needs cosmoSys $required_cosmosys or later," >&2
    echo "but cosmoSys $(short "$cosmosys_new") is $cosmosys_version." >&2
    exit 3
  fi
}
check_cosmosys_requirement "cosmoSys Requirements" "$cosmosys_req_url" "$cosmosys_req_new" ''
for plugin in $(catalog_all_plugins "$catalog"); do
  plugin_url=$(catalog_value "$catalog" "PLUGIN_${plugin}_SOURCE")
  [ -n "$plugin_url" ] || continue
  plugin_revision=$(catalog_value "$catalog" "PLUGIN_${plugin}_REVISION")
  for move in $plugin_moves; do
    [ "${move%%=*}" != "$plugin" ] || plugin_revision=${move#*=}
  done
  check_cosmosys_requirement "$plugin" "$plugin_url" "$plugin_revision" \
    "$(catalog_value "$catalog" "PLUGIN_${plugin}_SUBDIR")"
done

for move in $plugin_moves; do
  set_setting "$catalog" "PLUGIN_${move%%=*}_REVISION" "${move#*=}"
done

set_setting "$environment" COSMOSYS_REVISION "$cosmosys_new"
set_setting "$environment" COSMOSYS_REQ_REVISION "$cosmosys_req_new"
set_setting "$environment" RSPREADSHEET_REVISION "$rspreadsheet_new"
set_compose_default "$root_dir/compose.yml" COSMOSYS_REVISION "$cosmosys_new"
set_compose_default "$root_dir/compose.yml" RSPREADSHEET_REVISION "$rspreadsheet_new"
set_compose_default "$root_dir/compose.requirements.yml" COSMOSYS_REQ_REVISION "$cosmosys_req_new"

# Python packages, resolved once for every tool group together so that groups
# installed in the same environment agree, then written group by group with
# the hashes of every file of each version.
if [ "$python" = 1 ]; then
  python_groups=$(catalog_python_groups "$catalog" "$(catalog_value "$catalog" COSMOSYS_TOOL_GROUPS)" | catalog_join ' ')
  mkdir "$work_dir/python"
  for group in $python_groups; do
    catalog_value "$catalog" "TOOLS_${group}_PYTHON" | tr ' ' '\n' >"$work_dir/python/$group.in"
  done
  echo "Resolving the Python packages of $python_groups..."
  docker run --rm --entrypoint sh --volume "$work_dir/python:/lock" \
    --env "GROUPS=$python_groups" --env "PIP_TOOLS=$pip_tools_version" \
    --env "OWNER=$(id -u):$(id -g)" --env DEBIAN_FRONTEND=noninteractive \
    "$(catalog_value "$environment" REDMINE_IMAGE)" -c '
      set -eu
      apt-get -qq -o Acquire::Retries=5 update >/dev/null
      apt-get -qq -o Acquire::Retries=5 install -y --no-install-recommends python3-venv >/dev/null
      python3 -m venv /tmp/pip-tools
      /tmp/pip-tools/bin/pip install --quiet --disable-pip-version-check "pip-tools==$PIP_TOOLS"
      cd /lock
      cat ./*.in >all.in
      /tmp/pip-tools/bin/pip-compile --quiet --no-header --strip-extras --allow-unsafe \
        --output-file all.txt all.in
      for group in $GROUPS; do
        /tmp/pip-tools/bin/pip-compile --quiet --no-header --strip-extras --allow-unsafe \
          --generate-hashes --constraint all.txt --output-file "$group.txt" "$group.in"
      done
      chown -R "$OWNER" /lock
    '
  mkdir -p "$root_dir/docker/python"
  for group in $python_groups; do
    {
      echo "# Python packages of the $group tool group of plugins.conf, with their whole"
      echo "# dependency closure and the hashes of every file of each version."
      echo "# Generated by scripts/update-pins.sh --python; do not edit by hand."
      cat "$work_dir/python/$group.txt"
    } >"$root_dir/docker/python/$group.txt"
    if [ -n "$(git -C "$root_dir" ls-files --others --exclude-standard -- "docker/python/$group.txt")" ]; then
      echo "Warning: add docker/python/$group.txt to git; untracked files do not count in the image name." >&2
    fi
  done
fi

# The image names follow from the content, whatever changed.
set_compose_default "$root_dir/compose.yml" COSMOSYS_IMAGE "$(sh "$root_dir/scripts/image-tag.sh" base)"
set_compose_default "$root_dir/compose.requirements.yml" COSMOSYS_REQ_IMAGE "$(sh "$root_dir/scripts/image-tag.sh" requirements)"

# The table of the README, between its two markers.
{
  echo '| Component | Version | Commit | Tag |'
  echo '| --- | --- | --- | --- |'
  redmine_image=$(catalog_value "$environment" REDMINE_IMAGE)
  printf '| Redmine | %s | image manifest in `.env.example` | n/a |\n' \
    "$(printf '%s\n' "$redmine_image" | sed -n 's/^redmine:\([^@]*\).*/\1/p')"
  printf '| [cosmoSys](%s) | %s | `%s` | %s |\n' "${cosmosys_url%.git}" \
    "$cosmosys_version" "$(short "$cosmosys_new")" "$(describe_tag "$cosmosys_url" "$cosmosys_new")"
  printf '| [cosmoSys Requirements](%s) | %s | `%s` | %s |\n' "${cosmosys_req_url%.git}" \
    "$(plugin_version "$cosmosys_req_url" "$cosmosys_req_new" '' cosmosys_req)" \
    "$(short "$cosmosys_req_new")" "$(describe_tag "$cosmosys_req_url" "$cosmosys_req_new")"
  printf '| [rspreadsheet](%s) | n/a | `%s` | %s |\n' "${rspreadsheet_url%.git}" \
    "$(short "$rspreadsheet_new")" "$(describe_tag "$rspreadsheet_url" "$rspreadsheet_new")"
  for plugin in $(catalog_all_plugins "$catalog"); do
    plugin_options=
    for option in $(catalog_value "$catalog" COSMOSYS_OPTIONS); do
      case " $(catalog_value "$catalog" "OPTION_${option}_PLUGINS") " in
        *" $plugin "*) plugin_options="$plugin_options${plugin_options:+, }\`$option\`" ;;
      esac
    done
    plugin_local=$(catalog_value "$catalog" "PLUGIN_${plugin}_LOCAL")
    if [ -n "$plugin_local" ]; then
      printf '| `%s` (%s) | n/a | `%s/` in this repository | n/a |\n' "$plugin" "$plugin_options" "$plugin_local"
      continue
    fi
    plugin_url=$(catalog_value "$catalog" "PLUGIN_${plugin}_SOURCE")
    plugin_revision=$(catalog_value "$catalog" "PLUGIN_${plugin}_REVISION")
    printf '| [%s](%s) (%s) | %s | `%s` | %s |\n' "$plugin" "${plugin_url%.git}" "$plugin_options" \
      "$(plugin_version "$plugin_url" "$plugin_revision" "$(catalog_value "$catalog" "PLUGIN_${plugin}_SUBDIR")" "$plugin")" \
      "$(short "$plugin_revision")" "$(describe_tag "$plugin_url" "$plugin_revision")"
  done
  for option in $(catalog_value "$catalog" COSMOSYS_OPTIONS); do
    service_pin=$(catalog_value "$catalog" "OPTION_${option}_PINS" | cut -d ' ' -f 1)
    [ -n "$service_pin" ] || continue
    printf '| Services of `%s` | %s | image digests in `.env.example` | n/a |\n' "$option" \
      "$(catalog_value "$environment" "$service_pin" | sed -n 's/^[^:]*:\([^@]*\).*/\1/p')"
  done
  for group in $(catalog_python_groups "$catalog" "$(catalog_value "$catalog" COSMOSYS_TOOL_GROUPS)"); do
    printf '| Python tools `%s` | %s | hashes in `docker/python/%s.txt` | n/a |\n' "$group" \
      "$(for package in $(catalog_value "$catalog" "TOOLS_${group}_PYTHON"); do
          normalized=$(printf '%s' "$package" | tr 'A-Z_.' 'a-z--')
          sed -n "s/^$normalized==\([^ ]*\).*/$package \1/p" "$root_dir/docker/python/$group.txt" 2>/dev/null
        done | paste -sd ',' - | sed 's/,/, /g')" "$group"
  done
} >"$work_dir/table"
awk -v table="$work_dir/table" '
  /^<!-- pins:end -->$/ { inside = 0 }
  !inside { print }
  /^<!-- pins:start -->$/ { while ((getline line < table) > 0) print line; inside = 1; found = 1 }
  END { exit !found }
' "$root_dir/README.md" | replace_file "$root_dir/README.md"

# The summary of what moved, for the body of a pull request.
if [ -n "$summary_file" ]; then
  {
    if [ -s "$work_dir/changes" ]; then
      echo '| Component | From | To |'
      echo '| --- | --- | --- |'
      while IFS='|' read -r name url old new; do
        printf '| %s | `%s` | `%s` ([compare](%s/compare/%s...%s)) |\n' \
          "$name" "$(short "$old")" "$(short "$new")" "${url%.git}" "$(short "$old")" "$(short "$new")"
      done <"$work_dir/changes"
      while IFS='|' read -r name url old new; do
        echo
        echo "<details><summary>$name: commits since the previous pin</summary>"
        echo
        git -C "$(repository "$url")" log --format='- `%h` %s' "$old..$new" 2>/dev/null || true
        echo
        echo '</details>'
      done <"$work_dir/changes"
    else
      echo 'No pinned revision moved.'
    fi
    if [ "$python" = 1 ]; then
      echo
      echo 'The Python packages of the tool groups were resolved again.'
    fi
  } >"$summary_file"
fi

if [ -s "$work_dir/changes" ]; then
  while IFS='|' read -r name url old new; do
    echo "$name: $(short "$old") -> $(short "$new")"
  done <"$work_dir/changes"
else
  echo "No pinned revision moved; derived values rewritten."
fi

if [ "$run_check" = 1 ]; then
  sh "$root_dir/scripts/check-config.sh"
fi
