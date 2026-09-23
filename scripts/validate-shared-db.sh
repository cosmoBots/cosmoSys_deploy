#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

# Everything comes from the generated environment files below.
unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDMINE_SECRET_KEY_BASE \
  COSMOSYS_INITIAL_ADMIN_PASSWORD COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE \
  COSMOSYS_HTTP_PORT COSMOSYS_DB_MODE COSMOSYS_DB_HOST COSMOSYS_DB_NETWORK \
  COSMOSYS_DB_ADMIN_USER COSMOSYS_DB_CONNECTION_LIMIT COSMOSYS_COMPOSE_PROJECT \
  COSMOSYS_VARIANT COSMOSYS_ENV_FILE COMPOSE_PROJECT_NAME \
  COSMOSYS_PROXY_MODE COSMOSYS_HOSTNAME COSMOSYS_PROXY_TLS COSMOSYS_PROXY_NETWORK

suffix=$$
validation_directory=$(mktemp -d)
instance_a="validation_a_$suffix"
instance_b="validation_b_$suffix"
env_a="$validation_directory/a.env"
env_b="$validation_directory/b.env"

export COSMOSYS_SHARED_DB_PROJECT="csys_db_validation_$suffix"
export COSMOSYS_SHARED_DB_ENV_FILE="$validation_directory/shared-db.env"

shared_compose() {
  docker compose -p "$COSMOSYS_SHARED_DB_PROJECT" \
    --env-file "$COSMOSYS_SHARED_DB_ENV_FILE" \
    -f "$deployment_repository_dir/shared-db/compose.yml" "$@"
}

# The environment file of each instance names its variant, so no caller here
# has to remember which one it is.
instance_compose() {
  (
    COSMOSYS_ENV_FILE=$1
    export COSMOSYS_ENV_FILE
    shift
    deployment_compose "$@"
  )
}

cleanup() {
  cleanup_failed=0
  for instance_env in "$env_a" "$env_b"; do
    if [ -f "$instance_env" ]; then
      instance_compose "$instance_env" down --volumes --remove-orphans >/dev/null 2>&1 ||
        cleanup_failed=1
    fi
  done
  if [ -f "$COSMOSYS_SHARED_DB_ENV_FILE" ]; then
    shared_compose down --volumes --remove-orphans >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [ "$cleanup_failed" -eq 0 ]; then
    rm -rf -- "$validation_directory"
  else
    echo "WARNING: some validation containers, volumes or networks could not be removed." >&2
    echo "Their environment files are kept in $validation_directory" >&2
  fi
}
trap cleanup EXIT HUP INT TERM

cat >"$COSMOSYS_SHARED_DB_ENV_FILE" <<EOF
COSMOSYS_DB_ADMIN_PASSWORD=validation-admin-password-$suffix
COSMOSYS_DB_NETWORK=csys_db_validation_$suffix
COSMOSYS_DB_HOST=csys-db-validation-$suffix
EOF

# Only one Redmine runs at a time, so the validation fits on small hosts.
start_instance() {
  if ! instance_compose "$1" up -d --wait --build redmine; then
    instance_compose "$1" logs --no-color --tail 100 migrate bootstrap redmine >&2 || true
    return 1
  fi
}

echo "Starting shared PostgreSQL validation as $COSMOSYS_SHARED_DB_PROJECT..."
shared_compose up -d --wait postgres

provision="$deployment_repository_dir/scripts/provision-instance.sh"
"$provision" "$instance_a" "$env_a" >/dev/null
"$provision" --variant requirements "$instance_b" "$env_b" >/dev/null
if "$provision" "$instance_a" "$validation_directory/again.env" >/dev/null 2>&1; then
  echo "Provisioning accepted an instance that already exists" >&2
  exit 1
fi
test ! -e "$validation_directory/again.env"

# The variant belongs to the environment file; a shell that contradicts it is
# a mistake rather than a silent override.
if (
  COSMOSYS_ENV_FILE="$env_b"
  COSMOSYS_VARIANT=base
  export COSMOSYS_ENV_FILE COSMOSYS_VARIANT
  deployment_compose config --quiet
) >/dev/null 2>&1; then
  echo "A COSMOSYS_VARIANT contradicting the environment file was accepted" >&2
  exit 1
fi

start_instance "$env_a"
instance_compose "$env_a" exec -T redmine bundle exec rails runner \
  "actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); abort('cosmosys missing') unless actual.include?('cosmosys'); abort('cosmosys_req unexpectedly loaded') if actual.include?('cosmosys_req'); abort('missing help projects') unless Project.where(identifier: %w[csys_help csys_admin_help]).count == 2"
instance_compose "$env_a" stop redmine >/dev/null

start_instance "$env_b"
instance_compose "$env_b" exec -T redmine bundle exec rails runner \
  "actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); missing = %w[cosmosys cosmosys_req] - actual; abort(\"Missing plugins: #{missing.join(', ')}\") unless missing.empty?; abort('missing help projects') unless Project.where(identifier: %w[csys_help csys_admin_help]).count == 2"
instance_compose "$env_b" stop redmine >/dev/null

for project in "csys_$instance_a" "csys_$instance_b"; do
  if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project" \
    --filter label=com.docker.compose.service=db)" ]; then
    echo "$project started a local database" >&2
    exit 1
  fi
done

privileged=$(shared_compose exec -T postgres psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM pg_roles WHERE rolname IN ('csys_$instance_a', 'csys_$instance_b') AND (rolsuper OR rolcreatedb)")
test "$privileged" = 0

isolation_output=$(instance_compose "$env_a" run --rm --no-deps -T db-client \
  psql --dbname "csys_$instance_b" --command 'SELECT 1' 2>&1 || true)
case "$isolation_output" in
  *"CONNECT privilege"*) ;;
  *)
    echo "Unexpected result connecting instance A to instance B: $isolation_output" >&2
    exit 1
    ;;
esac

db_a() {
  instance_compose "$env_a" run --rm --no-deps -T db-client \
    psql --tuples-only --no-align --set ON_ERROR_STOP=1 "$@"
}

start_instance "$env_a"
db_a --command "CREATE TABLE csys_restore_probe (value text NOT NULL); INSERT INTO csys_restore_probe VALUES ('database-before-backup');" \
  >/dev/null
instance_compose "$env_a" exec -T redmine sh -c \
  "printf '%s' 'files-before-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

backup_directory=$(COSMOSYS_ENV_FILE="$env_a" \
  "$deployment_repository_dir/scripts/backup.sh" "$validation_directory/backups")

for manifest_line in \
  "database_mode=shared" \
  "compose_project=csys_$instance_a" \
  "database=csys_$instance_a" \
  "database_user=csys_$instance_a"; do
  if ! grep -qxF "$manifest_line" "$backup_directory/manifest.env"; then
    echo "Backup manifest lacks $manifest_line" >&2
    exit 1
  fi
done

db_a --command "UPDATE csys_restore_probe SET value = 'database-after-backup';" >/dev/null
instance_compose "$env_a" exec -T redmine sh -c \
  "printf '%s' 'files-after-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

COSMOSYS_ENV_FILE="$env_a" \
  RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \
  "$deployment_repository_dir/scripts/restore.sh" "$backup_directory" >/dev/null

database_value=$(db_a --command 'SELECT value FROM csys_restore_probe')
file_value=$(instance_compose "$env_a" exec -T redmine \
  cat /usr/src/redmine/files/csys-restore-probe.txt)
test "$database_value" = database-before-backup
test "$file_value" = files-before-backup

b_state=$(instance_compose "$env_b" run --rm --no-deps -T db-client \
  psql --tuples-only --no-align --command \
  "SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 'csys_restore_probe') || ',' || (SELECT count(*) FROM projects WHERE identifier = 'csys_help')")
test "$b_state" = "0,1"

echo "Shared PostgreSQL validation passed."
