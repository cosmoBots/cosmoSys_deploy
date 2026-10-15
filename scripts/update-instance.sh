#!/bin/sh
set -eu

# Compares the version an instance is running with the version this deployment
# declares, and updates the instance to it. The version of an instance lives in
# its own environment file, so instances on one host update independently of
# each other and of the checkout they share.

. "$(dirname -- "$0")/deployment-lib.sh"

usage() {
  cat >&2 <<EOF
Usage: COSMOSYS_ENV_FILE=FILE $0 [--check] [--yes] [--pins FILE]
       [--source REF] [--plugins SET[,SET...]] [--allow-plugin-removal]
       [--allow-stale-deployment] [--timeout SECONDS]

Reads the version and the optional plugin sets the instance runs from its
container, and the version this deployment declares from REF (origin/main by
default), and updates the instance to them: backup, new pins in the instance
environment file, image, recreation and verification. A failure restores the
previous image and plugin sets, which does not undo a migration that already
ran.

  --check                   Report and change nothing.
  --yes                     Apply on an instance whose COSMOSYS_UPDATE_MODE is
                            manual. Instances set to auto need no confirmation.
  --pins FILE               Take the declared versions from FILE (KEY=VALUE)
                            instead of from a git reference.
  --source REF              Git reference to read the declared versions from.
  --plugins SET[,SET...]    Change the optional plugin sets of the instance
                            (plugins.conf) as part of the update. An empty
                            value turns them all off.
  --allow-plugin-removal    Turn off plugin sets whose plugins have database
                            migrations applied. Their tables and settings stay.
  --allow-stale-deployment  Apply although this checkout differs from REF in
                            the files that end up in the image.
  --timeout SECONDS         How long to wait for the instance to become
                            healthy, 300 by default.

Exit status: 0 up to date or updated, 10 an update is available and was not
applied, 4 another update of this instance is already running, 3 refused,
2 usage or configuration error, with nothing touched, 1 the update failed
after having started to change the instance.
EOF
}

check_only=0
assume_yes=0
allow_stale=0
allow_plugin_removal=0
plugins_requested=0
plugins_argument=
pins_file=
source_ref=${COSMOSYS_UPDATE_SOURCE_REF:-origin/main}
wait_timeout=${COSMOSYS_UPDATE_TIMEOUT:-300}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --yes) assume_yes=1; shift ;;
    --allow-stale-deployment) allow_stale=1; shift ;;
    --allow-plugin-removal) allow_plugin_removal=1; shift ;;
    --pins|--source|--timeout|--plugins)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      case "$1" in
        --pins) pins_file=$2 ;;
        --source) source_ref=$2 ;;
        --timeout) wait_timeout=$2 ;;
        --plugins) plugins_requested=1; plugins_argument=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$wait_timeout" in
  ''|*[!0-9]*)
    echo "--timeout must be a number of seconds" >&2
    exit 2
    ;;
esac
if [ -n "$pins_file" ] && [ ! -f "$pins_file" ]; then
  echo "Pins file does not exist: $pins_file" >&2
  exit 2
fi

instance_env=${COSMOSYS_ENV_FILE:-"$deployment_repository_dir/.env"}
variant=$(deployment_variant)
database_mode=$(deployment_db_mode)
if [ "$plugins_requested" = 1 ]; then
  target_plugins=$(catalog_options "$deployment_catalog" "$plugins_argument") || exit 2
else
  target_plugins=$(deployment_plugins) || exit 2
fi
target_tools=$(catalog_option_tools "$deployment_catalog" "$target_plugins")
target_plugins=$(printf '%s\n' "$target_plugins" | catalog_join ,)
target_tools=$(printf '%s\n' "$target_tools" | catalog_join ,)
update_mode=$(deployment_setting COSMOSYS_UPDATE_MODE manual)

case "$update_mode" in
  manual|auto) ;;
  *)
    echo "COSMOSYS_UPDATE_MODE must be manual or auto" >&2
    exit 2
    ;;
esac

# The running container is the only trustworthy description of what an instance
# actually runs: an environment file can already name a version that has not
# been built or activated yet.
redmine_container=$(deployment_compose ps -q redmine)
if [ -z "$redmine_container" ]; then
  echo "The redmine service is not running; start the instance before updating it" >&2
  exit 2
fi

running_image=$(docker inspect --format '{{.Config.Image}}' "$redmine_container")
running_image_id=$(docker inspect --format '{{.Image}}' "$redmine_container")
running_cosmosys=$(deployment_container_label "$redmine_container" eu.cosmobots.cosmosys.revision)
running_rspreadsheet=$(deployment_container_label "$redmine_container" eu.cosmobots.rspreadsheet.revision)
running_cosmosys_req=$(deployment_container_label "$redmine_container" eu.cosmobots.cosmosys-req.revision)

# The plugin sets the container was started with. Images built before
# plugins.conf have no tools label; they carried Kroki, LaTeX, the notebook
# viewer and PORIS inside and say so in labels of their own.
if [ "$(docker inspect --format '{{index .Config.Labels "eu.cosmobots.tools"}}' "$redmine_container")" = '<no value>' ]; then
  running_plugins=
  if [ "$(deployment_container_label "$redmine_container" eu.cosmobots.redmine-kroki.revision)" != unknown ]; then
    running_plugins=kroki
  fi
  if [ "$(deployment_container_label "$redmine_container" eu.cosmobots.redmine-cbots-latex.revision)" != unknown ]; then
    running_plugins="$running_plugins,latex"
  fi
  if [ "$(deployment_container_label "$redmine_container" eu.cosmobots.redmine-notebook-preview.revision)" != unknown ]; then
    running_plugins="$running_plugins,notebooks"
  fi
  if [ "$(deployment_container_label "$redmine_container" eu.cosmobots.cosmosys-poris.revision)" != unknown ]; then
    running_plugins="$running_plugins,poris"
  fi
else
  running_plugins=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$redmine_container" |
    sed -n 's/^COSMOSYS_PLUGINS=//p' | tail -n 1)
fi
running_tools=
if running_sets=$(catalog_options "$deployment_catalog" "$running_plugins" 2>/dev/null); then
  running_plugins=$(printf '%s\n' "$running_sets" | catalog_join ,)
  running_tools=$(catalog_option_tools "$deployment_catalog" "$running_sets" | catalog_join ,)
fi

# An instance provisioned before the variant was recorded runs the Requirements
# image while its environment file says nothing, so it resolves to the base
# variant. Updating it then would rebuild it as the base variant and take the
# requirements plugin away from it.
if [ "$variant" = base ] && [ "$running_cosmosys_req" != unknown ]; then
  echo "This instance runs cosmoSys Requirements $running_cosmosys_req, but its" >&2
  echo "environment file does not say so and it resolves to the base variant." >&2
  echo "Add COSMOSYS_VARIANT=requirements to $instance_env before updating it." >&2
  exit 3
fi

# Prints one KEY=VALUE setting out of the text on standard input.
declared_setting() {
  sed -n "s/^$1=//p" | tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

# Prints the default of a Compose interpolation such as ${COSMOSYS_IMAGE:-...},
# which is where the image names of this deployment are declared.
declared_compose_image() {
  sed -n "s/.*\${$1:-\([^}]*\)}.*/\1/p" | head -n 1
}

deployment_drift=unknown

if [ -n "$pins_file" ]; then
  declared_env=$(cat "$pins_file")
  declared_compose=$declared_env
  declared_requirements=$declared_env
  declared_catalog=$(cat "$deployment_catalog")
else
  if ! git -C "$deployment_repository_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$deployment_repository_dir is not a git checkout, so the declared" >&2
    echo "versions cannot be read from $source_ref. Pass --pins instead." >&2
    exit 2
  fi
  # Only a remote-tracking reference is worth fetching, and it says by itself
  # which remote to fetch from. A local reference, a tag or the reference of
  # another checkout is read as it is.
  source_full_ref=$(git -C "$deployment_repository_dir" \
    rev-parse --symbolic-full-name "$source_ref" 2>/dev/null || true)
  case "$source_full_ref" in
    refs/remotes/*)
      source_remote=${source_full_ref#refs/remotes/}
      source_remote=${source_remote%%/*}
      # Not being able to read the declared version changes nothing and says
      # nothing about the version itself, so it is a configuration error here
      # and not a failed update that should stop a run over a whole host.
      if ! git -C "$deployment_repository_dir" fetch --quiet "$source_remote"; then
        echo "Cannot fetch from $source_remote, so the declared version cannot be read." >&2
        echo "An unattended update needs a read-only deploy key on this host, because" >&2
        echo "no SSH agent is forwarded to it. The instance was left untouched." >&2
        exit 2
      fi
      ;;
  esac
  if ! git -C "$deployment_repository_dir" rev-parse --verify --quiet "$source_ref" >/dev/null; then
    echo "Unknown git reference: $source_ref" >&2
    exit 2
  fi
  declared_env=$(git -C "$deployment_repository_dir" show "$source_ref:.env.example")
  declared_compose=$(git -C "$deployment_repository_dir" show "$source_ref:compose.yml")
  declared_requirements=$(git -C "$deployment_repository_dir" show "$source_ref:compose.requirements.yml")
  declared_catalog=$(git -C "$deployment_repository_dir" show "$source_ref:plugins.conf")

  # Everything that ends up inside the image, so that a stale checkout cannot
  # publish something else under the image tag that names those revisions.
  # shellcheck disable=SC2046
  if git -C "$deployment_repository_dir" diff --quiet "$source_ref" -- \
    Dockerfile plugins.conf config bootstrap kroki_compat docker \
    scripts/catalog-lib.sh compose.yml compose.requirements.yml \
    compose.shared-db.yml compose.proxy.yml \
    $(catalog_option_compose_files "$deployment_catalog" "$(catalog_value "$deployment_catalog" COSMOSYS_OPTIONS)"); then
    deployment_drift=no
  else
    deployment_drift=yes
  fi
fi

declared_cosmosys=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_REVISION)
declared_cosmosys_req=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_REQ_REVISION)
declared_rspreadsheet=$(printf '%s\n' "$declared_env" | declared_setting RSPREADSHEET_REVISION)
declared_redmine_image=$(printf '%s\n' "$declared_env" | declared_setting REDMINE_IMAGE)
declared_postgres_image=$(printf '%s\n' "$declared_env" | declared_setting POSTGRES_IMAGE)
declared_image=$(printf '%s\n' "$declared_compose" | declared_compose_image COSMOSYS_IMAGE)
declared_req_image=$(printf '%s\n' "$declared_requirements" | declared_compose_image COSMOSYS_REQ_IMAGE)

if [ -n "$pins_file" ]; then
  # A pins file may name the images explicitly instead of relying on Compose.
  pins_image=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_IMAGE)
  pins_req_image=$(printf '%s\n' "$declared_env" | declared_setting COSMOSYS_REQ_IMAGE)
  declared_image=${pins_image:-$declared_image}
  declared_req_image=${pins_req_image:-$declared_req_image}
fi

# The last build stage adds the tools of the plugin sets to the image name.
if [ "$variant" = requirements ]; then
  image_setting=COSMOSYS_REQ_IMAGE
  declared_reference=$(deployment_image_with_tools "$declared_req_image" "$target_tools")
else
  image_setting=COSMOSYS_IMAGE
  declared_reference=$(deployment_image_with_tools "$declared_image" "$target_tools")
fi

for required in declared_cosmosys declared_rspreadsheet declared_redmine_image \
  declared_postgres_image declared_image declared_catalog; do
  eval "required_value=\$$required"
  if [ -z "$required_value" ]; then
    echo "The declared versions are incomplete: ${required#declared_} is missing" >&2
    exit 2
  fi
done

printf 'Instance %s, %s variant, %s database.\n' \
  "$(deployment_setting COMPOSE_PROJECT_NAME cosmosys)" "$variant" "$database_mode"
printf 'Running:  %s\n' "$running_image"
printf '          cosmoSys %s' "$running_cosmosys"
if [ "$variant" = requirements ]; then
  printf ', cosmoSys Requirements %s' "$running_cosmosys_req"
fi
printf ', rspreadsheet %s\n' "$running_rspreadsheet"
printf '          plugin sets: %s\n' "${running_plugins:-none}"
printf 'Declared: %s\n' "$declared_reference"
printf '          cosmoSys %s' "$declared_cosmosys"
if [ "$variant" = requirements ]; then
  printf ', cosmoSys Requirements %s' "$declared_cosmosys_req"
fi
printf ', rspreadsheet %s\n' "$declared_rspreadsheet"
printf '          plugin sets: %s\n' "${target_plugins:-none}"

if [ "$deployment_drift" = yes ]; then
  echo "Warning: this checkout differs from $source_ref in files that end up in" >&2
  echo "the image, so a build here would not match what $source_ref describes." >&2
fi

if [ "$running_image" = "$declared_reference" ] && [ "$running_plugins" = "$target_plugins" ]; then
  echo "The instance is up to date."
  exit 0
fi

echo "An update is available."

if [ "$check_only" = 1 ]; then
  exit 10
fi

if [ "$update_mode" = manual ] && [ "$assume_yes" = 0 ]; then
  echo "This instance is set to manual updates; rerun with --yes to apply it."
  exit 10
fi

if [ "$deployment_drift" = yes ] && [ "$allow_stale" = 0 ]; then
  echo "Refusing to update from a checkout that differs from $source_ref in the" >&2
  echo "files that end up in the image. The image built here would be tagged with" >&2
  echo "the revisions it declares while containing something else, and that image" >&2
  echo "outlives this update: it is what a rollback starts again and what every" >&2
  echo "backup manifest records." >&2
  echo "Update the checkout, or pass --allow-stale-deployment deliberately." >&2
  exit 3
fi

# A major PostgreSQL version is not an update but a migration with its own dump
# and restore, so this script never starts one behind the operator's back.
if [ "$database_mode" = local ]; then
  database_container=$(deployment_compose ps -q db)
  if [ -n "$database_container" ]; then
    running_postgres=$(docker inspect --format '{{.Config.Image}}' "$database_container")
    running_major=$(printf '%s\n' "$running_postgres" | sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p')
    declared_major=$(printf '%s\n' "$declared_postgres_image" | sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p')
    if [ -n "$running_major" ] && [ -n "$declared_major" ] &&
      [ "$running_major" != "$declared_major" ]; then
      echo "Refusing to update: PostgreSQL would go from $running_major to $declared_major." >&2
      echo "A major version needs its own dump and restore, not a recreation." >&2
      exit 3
    fi
  fi
fi

# Turning a plugin set off leaves the tables, settings and content of its
# plugins behind, and nothing can turn that back into a working state but the
# backup. A plugin without migrations has nothing of the sort to leave.
target_plugin_dirs=" $(catalog_option_plugins "$deployment_catalog" "$(printf '%s' "$target_plugins" | tr ',' ' ')" | catalog_join ' ') "
removed_plugins=
for plugin in $(catalog_option_plugins "$deployment_catalog" "$(printf '%s' "$running_plugins" | tr ',' ' ')"); do
  case "$target_plugin_dirs" in
    *" $plugin "*) ;;
    *) removed_plugins="$removed_plugins $plugin" ;;
  esac
done
if [ -n "$removed_plugins" ]; then
  migrated_plugins=$(deployment_compose exec -T redmine bundle exec rails runner \
    "%w[$removed_plugins].each { |plugin| puts plugin if ActiveRecord::Base.connection.select_value(\"SELECT COUNT(*) FROM schema_migrations WHERE version LIKE '%-#{plugin}'\").to_i.positive? }") ||
    { echo "Cannot tell whether the plugins being turned off have migrations." >&2; exit 2; }
  if [ -n "$migrated_plugins" ] && [ "$allow_plugin_removal" = 0 ]; then
    echo "Refusing to turn off plugins with database migrations applied:" >&2
    printf '  %s\n' $migrated_plugins >&2
    echo "Their tables, settings and macros would stay behind without them. Pass" >&2
    echo "--allow-plugin-removal to turn them off anyway; the backup taken before" >&2
    echo "the update is the only way back." >&2
    exit 3
  fi
fi

# Two updates of one instance at the same time would run two recreations
# against the same Compose project, so the second one waits for another day
# rather than for the first one: a timer firing while somebody updates by hand
# has nothing useful to do. Instances are locked one by one, so different
# instances on one host still update in parallel.
lock_name=$(printf '%s' "$(deployment_setting COMPOSE_PROJECT_NAME cosmosys)" |
  tr -c 'A-Za-z0-9_.-' '_')
lock_directory="${COSMOSYS_UPDATE_LOCK_DIR:-${TMPDIR:-/tmp}}/cosmosys-update-$lock_name.lock"

lock_acquired=0
work_directory=
rollback_needed=0

cleanup() {
  if [ "$lock_acquired" = 1 ]; then
    rm -rf -- "$lock_directory"
  fi
  if [ -n "$work_directory" ] && [ "$rollback_needed" = 0 ]; then
    rm -rf -- "$work_directory"
  fi
}
trap cleanup EXIT HUP INT TERM

if ! mkdir "$lock_directory" 2>/dev/null; then
  echo "Another update of this instance is already running." >&2
  if [ -r "$lock_directory/pid" ]; then
    echo "Its lock is $lock_directory, held by process $(cat "$lock_directory/pid")." >&2
  else
    echo "Its lock is $lock_directory." >&2
  fi
  echo "Remove that directory only after making sure that no update is running." >&2
  exit 4
fi
lock_acquired=1
printf '%s\n' "$$" >"$lock_directory/pid"

work_directory=$(mktemp -d)

(umask 077 && cat "$instance_env" >"$work_directory/previous.env")
printf '%s\n' "$declared_catalog" >"$work_directory/declared-plugins.conf"

# The way back starts the image the instance runs now, by identity: the name
# it was started with may already point to another image, or be rebuilt from
# a checkout that has moved on.
rollback_image="cosmosys-rollback/$(printf '%s' "$lock_name" | tr 'A-Z.' 'a-z_'):previous"
docker tag "$running_image_id" "$rollback_image"

# Replaces one setting in place, keeping the file's own permissions and inode.
set_instance_setting() {
  awk -v key="$1" -v value="$2" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 {
      if (!found) {
        print key "=" value
        found = 1
      }
      next
    }
    { print }
    END { if (!found) print key "=" value }
  ' "$instance_env" >"$work_directory/instance.env"
  cat "$work_directory/instance.env" >"$instance_env"
}

# Removes one setting, keeping the file's own permissions and inode.
remove_instance_setting() {
  awk -v key="$1" 'index($0, key "=") != 1 { print }' \
    "$instance_env" >"$work_directory/instance.env"
  cat "$work_directory/instance.env" >"$instance_env"
}

restore_previous_version() {
  echo "Restoring the previous version of the instance..." >&2
  cat "$work_directory/previous.env" >"$instance_env"
  # The name the instance ran under is kept while it still means the same
  # image; otherwise the tag taken before the update stands in for it.
  previous_image=$rollback_image
  if [ "$(docker image inspect --format '{{.Id}}' "$running_image" 2>/dev/null)" = "$running_image_id" ]; then
    previous_image=$running_image
  fi
  set_instance_setting "$image_setting" "$previous_image"
  set_instance_setting COSMOSYS_PLUGINS "$running_plugins"
  set_instance_setting COSMOSYS_TOOLS "$running_tools"
  if deployment_compose up -d --wait --wait-timeout "$wait_timeout" --remove-orphans redmine >&2 &&
    [ "$(docker inspect --format '{{.Image}}' "$(deployment_compose ps -q redmine)")" = "$running_image_id" ]; then
    echo "The instance runs its previous image again, $previous_image." >&2
  else
    echo "The instance did not come back up on its previous image, $previous_image." >&2
  fi
  cat >&2 <<EOF

The database was not restored. If the update had already run its migrations,
the previous image is running against a migrated schema, and the only way back
is the backup taken before the update:

  RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \\
    COSMOSYS_ENV_FILE=$instance_env \\
    $deployment_repository_dir/scripts/restore.sh $backup_directory

A copy of the environment file as it was before the update is kept in
$work_directory/previous.env
EOF
}

update_failed() {
  echo "$1" >&2
  rollback_needed=1
  restore_previous_version
  exit 1
}

echo "Backing up the instance before updating it..."
if ! backup_directory=$("$deployment_repository_dir/scripts/backup.sh" \
  ${COSMOSYS_BACKUP_ROOT:+"$COSMOSYS_BACKUP_ROOT"}); then
  echo "The backup failed, so the instance was left untouched." >&2
  exit 1
fi
echo "Backup: $backup_directory"

set_instance_setting COSMOSYS_REVISION "$declared_cosmosys"
set_instance_setting RSPREADSHEET_REVISION "$declared_rspreadsheet"
set_instance_setting REDMINE_IMAGE "$declared_redmine_image"
set_instance_setting POSTGRES_IMAGE "$declared_postgres_image"
if [ "$variant" = requirements ]; then
  set_instance_setting COSMOSYS_REQ_REVISION "$declared_cosmosys_req"
fi
set_instance_setting "$image_setting" "$declared_reference"
set_instance_setting COSMOSYS_PLUGINS "$target_plugins"
set_instance_setting COSMOSYS_TOOLS "$target_tools"
# The images of the services a plugin set adds belong to the instance too, so
# that moving the checkout does not change them behind the updater's back.
for pinned_setting in $(catalog_option_pins "$deployment_catalog" "$(printf '%s' "$target_plugins" | tr ',' ' ')"); do
  pinned_value=$(printf '%s\n' "$declared_env" | declared_setting "$pinned_setting")
  if [ -n "$pinned_value" ]; then
    set_instance_setting "$pinned_setting" "$pinned_value"
  fi
done
# Settings of the time when each optional plugin had an image of its own.
for obsolete_setting in COSMOSYS_KROKI_ENABLED COSMOSYS_LATEX_ENABLED \
  COSMOSYS_NOTEBOOK_PREVIEW_ENABLED COSMOSYS_PORIS_ENABLED \
  REDMINE_KROKI_REVISION COSMOSYS_KROKI_REVISION COSMOSYS_LATEX_REVISION \
  REDMINE_NOTEBOOK_PREVIEW_REVISION COSMOSYS_PORIS_REVISION \
  COSMOSYS_KROKI_IMAGE COSMOSYS_REQ_KROKI_IMAGE \
  COSMOSYS_REQ_KROKI_LATEX_IMAGE \
  COSMOSYS_REQ_KROKI_LATEX_NOTEBOOK_PREVIEW_IMAGE \
  COSMOSYS_REQ_KROKI_LATEX_NOTEBOOK_PREVIEW_PORIS_IMAGE; do
  remove_instance_setting "$obsolete_setting"
done

# The only step that knows where an image comes from. With a registry this
# becomes a pull and nothing else in this script changes.
update_acquire_image() {
  deployment_compose build redmine
}

image_started=$(date +%s)
echo "Building $declared_reference..."
if ! update_acquire_image; then
  update_failed "The image could not be built."
fi
echo "Image ready in $(($(date +%s) - image_started)) s."

echo "Recreating the instance..."
if ! deployment_compose up -d --wait --wait-timeout "$wait_timeout" --remove-orphans redmine; then
  deployment_compose logs --no-color --tail 100 migrate bootstrap redmine >&2 || true
  update_failed "The instance did not become healthy within $wait_timeout s."
fi

updated_container=$(deployment_compose ps -q redmine)
if [ -z "$updated_container" ]; then
  update_failed "The redmine service is not running after the update."
fi

updated_cosmosys=$(deployment_container_label "$updated_container" eu.cosmobots.cosmosys.revision)
if [ "$updated_cosmosys" != "$declared_cosmosys" ]; then
  update_failed "The instance runs cosmoSys $updated_cosmosys instead of $declared_cosmosys."
fi
if [ "$variant" = requirements ]; then
  updated_cosmosys_req=$(deployment_container_label "$updated_container" eu.cosmobots.cosmosys-req.revision)
  if [ "$updated_cosmosys_req" != "$declared_cosmosys_req" ]; then
    update_failed "The instance runs cosmoSys Requirements $updated_cosmosys_req instead of $declared_cosmosys_req."
  fi
fi

# The catalog inside the image says which revision of each optional plugin it
# carries; it has to be the one declared.
if ! deployment_compose exec -T redmine cat /opt/cosmosys-deploy/plugins.conf |
  cmp -s - "$work_directory/declared-plugins.conf"; then
  update_failed "The updated image carries other optional plugins than the ones declared."
fi

# Exactly the plugins of the variant and of the active sets, and no dormant one.
expected_plugins=cosmosys
if [ "$variant" = requirements ]; then
  expected_plugins="cosmosys cosmosys_req"
fi
expected_plugins="$expected_plugins $(catalog_option_plugins "$deployment_catalog" "$(printf '%s' "$target_plugins" | tr ',' ' ')" | catalog_join ' ')"
if ! deployment_compose exec -T redmine bundle exec rails runner \
  "expected = %w[$expected_plugins].select { |plugin| File.read(File.join('plugins', plugin, 'init.rb')).include?('Plugin.register') }; actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); abort(\"registered plugins: #{actual.sort.join(', ')}; expected: #{expected.sort.join(', ')}\") unless actual.sort == expected.sort"; then
  update_failed "The updated instance does not register exactly the expected plugins."
fi
case ",$target_plugins," in
  *,adr,*)
    if ! deployment_compose exec -T redmine bundle exec rails runner \
      "abort('the csAdr tracker is missing') unless CosmosysAdr.tracker; missing = CosmosysAdr::STATUS_KEYS.reject { |key| CosmosysAdr.status(key) }; abort(\"ADR statuses are missing: #{missing.join(', ')}\") unless missing.empty?; abort('the adr item kind is not registered by cosmosys_adr') unless Cosmosys::ItemKindRegistry.registered?('adr') && Cosmosys::ItemKindRegistry.fetch('adr').provider == :cosmosys_adr"; then
      update_failed "The updated instance does not provide ADRs."
    fi
    ;;
esac
case ",$target_plugins," in
  *,kroki,*)
    if ! deployment_compose exec -T redmine bundle exec rails runner \
      "abort('Redmine-Kroki settings compatibility initializer is missing') unless Setting.singleton_class.ancestors.include?(RedmineKrokiSettingsCompatibility::SettingPatch); settings = Setting.plugin_redmine_kroki; abort('Redmine-Kroki settings are not readable by symbol key') unless settings[:kroki_url] == settings['kroki_url']"; then
      update_failed "The updated instance lacks the Kroki settings compatibility initializer."
    fi
    ;;
esac
case ",$target_plugins," in
  *,latex,*|*,notebooks,*)
    if ! deployment_compose exec -T redmine bundle exec rails runner \
    "abort('Redmine Cbots LaTeX renderer is not loaded') unless defined?(RedmineCbotsLatex::LatexRenderer); python = Setting.plugin_redmine_cbots_latex['python_bin'].presence || '/usr/bin/python3'; abort(\"matplotlib is unavailable to #{python}; the LaTeX plugin settings should name #{ENV['LATEX_PYTHON_BIN']}\") unless system(python, '-c', 'import matplotlib', out: File::NULL, err: File::NULL); require 'tmpdir'; rendered = RedmineCbotsLatex::LatexRenderer.render_html('<p>\\(x^2\\)</p>', cache_dir: Dir.mktmpdir); abort('static LaTeX rendering did not produce an image') unless rendered.include?('data:image/png;base64,')"; then
      update_failed "The updated image does not provide static LaTeX rendering."
    fi
    ;;
esac
case ",$target_plugins," in
  *,notebooks,*)
    if ! deployment_compose exec -T redmine bundle exec rails runner \
    "require 'open3'; require 'json'; settings = Setting.plugin_redmine_notebook_preview; jupyter = settings['jupyter_bin']; abort(\"#{jupyter} is not executable; the notebook preview settings should name #{ENV['JUPYTER_BIN']}\") unless File.executable?(jupyter.to_s); abort('matplotlib is unavailable next to jupyter') unless system(File.join(File.dirname(jupyter), 'python'), '-c', 'import matplotlib', out: File::NULL, err: File::NULL); notebook = JSON.generate('cells' => [{'cell_type' => 'markdown', 'metadata' => {}, 'source' => ['Notebook preview check']}], 'metadata' => {}, 'nbformat' => 4, 'nbformat_minor' => 5); html, error, status = Open3.capture3(jupyter, 'nbconvert', '--to', 'html', '--template', 'basic', '--stdin', '--stdout', stdin_data: notebook); abort(\"nbconvert failed: #{error}\") unless status.success? && html.include?('Notebook preview check')"; then
      update_failed "The updated image does not convert notebooks."
    fi
    ;;
esac

case ",$target_plugins," in
  *,poris,*)
    if ! deployment_compose exec -T redmine bundle exec rails runner \
    "require 'net/http'; kinds = %w[poris_sys poris_param poris_mode poris_value poris_cmd]; abort('the poris project profile is not registered') unless Cosmosys::ProjectProfileRegistry.registered?('poris'); missing = kinds.reject { |kind| Cosmosys::ItemKindRegistry.registered?(kind) }; abort(\"PORIS item kinds are not registered: #{missing.join(', ')}\") unless missing.empty?; abort('the PORIS trackers are missing') unless Tracker.where(csys_key: kinds).count == kinds.size; viewer = Rails.root.join('plugins/cosmosys_poris/assets/javascripts/poris_viewer'); bundle = viewer.join('prod.js'); abort('the PORIS viewer bundle is missing') unless bundle.file? && bundle.size > 100_000 && viewer.join('style.css').file?; abort('the PORIS viewer bundle needs Node: it refers to process.env') if bundle.read.match?(/process\\.env/); path = ActionController::Base.helpers.asset_path('plugin_assets/cosmosys_poris/poris_viewer/prod.js'); response = Net::HTTP.get_response(URI(\"http://127.0.0.1:3000#{path}\")); abort(\"the PORIS viewer bundle answered #{response.code} at #{path}\") unless response.is_a?(Net::HTTPSuccess)"; then
      update_failed "The updated instance does not provide PORIS models and their viewer."
    fi
    ;;
esac

docker image rm "$rollback_image" >/dev/null 2>&1 || true

cat <<EOF
The instance is updated and healthy.
  image:       $declared_reference
  plugin sets: ${target_plugins:-none}
  backup:      $backup_directory
EOF
