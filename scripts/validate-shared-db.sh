#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

# Everything comes from the generated environment files below.
unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDMINE_SECRET_KEY_BASE \
  COSMOSYS_INITIAL_ADMIN_PASSWORD COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE \
  COSMOSYS_HTTP_PORT COSMOSYS_DB_MODE COSMOSYS_DB_HOST COSMOSYS_DB_NETWORK \
  COSMOSYS_DB_ADMIN_USER COSMOSYS_DB_CONNECTION_LIMIT COSMOSYS_COMPOSE_PROJECT \
  COSMOSYS_VARIANT COSMOSYS_ENV_FILE COMPOSE_PROJECT_NAME

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

instance_compose() {
  (
    COSMOSYS_ENV_FILE=$1
    COSMOSYS_VARIANT=$2
    export COSMOSYS_ENV_FILE COSMOSYS_VARIANT
    shift 2
    deployment_compose "$@"
  )
}

cleanup() {
  cleanup_failed=0
  for instance_env in "$env_a" "$env_b"; do
    if [ -f "$instance_env" ]; then
      instance_compose "$instance_env" base down --volumes --remove-orphans >/dev/null 2>&1 ||
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

start_instance() {
  if ! instance_compose "$1" "$2" up -d --wait redmine; then
    instance_compose "$1" "$2" logs --no-color --tail 100 migrate bootstrap redmine >&2 || true
    return 1
  fi
}

echo "Starting shared PostgreSQL validation as $COSMOSYS_SHARED_DB_PROJECT..."
shared_compose up -d --wait postgres

provision="$deployment_repository_dir/scripts/provision-shared-db.sh"
"$provision" "$instance_a" "$env_a" 0 >/dev/null
"$provision" "$instance_b" "$env_b" 0 >/dev/null
if "$provision" "$instance_a" "$validation_directory/again.env" 0 >/dev/null 2>&1; then
  echo "Provisioning accepted an instance that already exists" >&2
  exit 1
fi
test ! -e "$validation_directory/again.env"

start_instance "$env_a" base
start_instance "$env_b" requirements

for project in "csys_$instance_a" "csys_$instance_b"; do
  if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project" \
    --filter label=com.docker.compose.service=db)" ]; then
    echo "$project started a local database" >&2
    exit 1
  fi
done

instance_compose "$env_a" base exec -T redmine bundle exec rails runner \
  "actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); abort('cosmosys missing') unless actual.include?('cosmosys'); abort('cosmosys_req unexpectedly loaded') if actual.include?('cosmosys_req'); abort('missing help projects') unless Project.where(identifier: %w[csys_help csys_admin_help]).count == 2"
instance_compose "$env_b" requirements exec -T redmine bundle exec rails runner \
  "actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); missing = %w[cosmosys cosmosys_req] - actual; abort(\"Missing plugins: #{missing.join(', ')}\") unless missing.empty?; abort('missing help projects') unless Project.where(identifier: %w[csys_help csys_admin_help]).count == 2"

privileged=$(shared_compose exec -T postgres psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM pg_roles WHERE rolname IN ('csys_$instance_a', 'csys_$instance_b') AND (rolsuper OR rolcreatedb)")
test "$privileged" = 0

isolation_output=$(instance_compose "$env_a" base run --rm --no-deps -T db-client \
  psql --dbname "csys_$instance_b" --command 'SELECT 1' 2>&1 || true)
case "$isolation_output" in
  *"CONNECT privilege"*) ;;
  *)
    echo "Unexpected result connecting instance A to instance B: $isolation_output" >&2
    exit 1
    ;;
esac

db_a() {
  instance_compose "$env_a" base run --rm --no-deps -T db-client \
    psql --tuples-only --no-align --set ON_ERROR_STOP=1 "$@"
}

db_a --command "CREATE TABLE csys_restore_probe (value text NOT NULL); INSERT INTO csys_restore_probe VALUES ('database-before-backup');" \
  >/dev/null
instance_compose "$env_a" base exec -T redmine sh -c \
  "printf '%s' 'files-before-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

backup_directory=$(COSMOSYS_ENV_FILE="$env_a" COSMOSYS_VARIANT=base \
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
instance_compose "$env_a" base exec -T redmine sh -c \
  "printf '%s' 'files-after-backup' > /usr/src/redmine/files/csys-restore-probe.txt"

COSMOSYS_ENV_FILE="$env_a" COSMOSYS_VARIANT=base \
  RESTORE_CONFIRMATION=ERASE_EXISTING_COSMOSYS_DATA \
  "$deployment_repository_dir/scripts/restore.sh" "$backup_directory" >/dev/null

database_value=$(db_a --command 'SELECT value FROM csys_restore_probe')
file_value=$(instance_compose "$env_a" base exec -T redmine \
  cat /usr/src/redmine/files/csys-restore-probe.txt)
test "$database_value" = database-before-backup
test "$file_value" = files-before-backup

instance_compose "$env_b" requirements exec -T redmine ruby -rnet/http -e \
  "exit(Net::HTTP.get_response(URI('http://127.0.0.1:3000/')).is_a?(Net::HTTPSuccess) ? 0 : 1)"
b_probe_tables=$(instance_compose "$env_b" requirements run --rm --no-deps -T db-client \
  psql --tuples-only --no-align --command "SELECT count(*) FROM pg_tables WHERE tablename = 'csys_restore_probe'")
test "$b_probe_tables" = 0

echo "Shared PostgreSQL validation passed."
