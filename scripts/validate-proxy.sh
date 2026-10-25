#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

# Everything comes from the generated environment files below.
unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDMINE_SECRET_KEY_BASE \
  COSMOSYS_INITIAL_ADMIN_PASSWORD COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE \
  COSMOSYS_HTTP_PORT COSMOSYS_DB_MODE COSMOSYS_DB_HOST COSMOSYS_DB_NETWORK \
  COSMOSYS_DB_ADMIN_USER COSMOSYS_DB_CONNECTION_LIMIT COSMOSYS_COMPOSE_PROJECT \
  COSMOSYS_VARIANT COSMOSYS_ENV_FILE COMPOSE_PROJECT_NAME \
  COSMOSYS_PROXY_MODE COSMOSYS_HOSTNAME COSMOSYS_PROXY_TLS COSMOSYS_PROXY_NETWORK \
  COSMOSYS_PROXY_BIND_ADDRESS COSMOSYS_PROXY_HTTP_PORT COSMOSYS_PROXY_HTTPS_PORT \
  COSMOSYS_COMPOSE_OVERLAYS

suffix=$$
validation_directory=$(mktemp -d)
instance="proxy_$suffix"
instance_env="$validation_directory/instance.env"
public_host="csys-$suffix.validation.test"
unknown_host="unknown-$suffix.validation.test"
proxy_project="csys_proxy_validation_$suffix"
provision="$deployment_repository_dir/scripts/provision-instance.sh"

export COSMOSYS_SHARED_DB_PROJECT="csys_db_validation_$suffix"
export COSMOSYS_SHARED_DB_ENV_FILE="$validation_directory/shared-db.env"
export COSMOSYS_PROXY_ENV_FILE="$validation_directory/proxy.env"

shared_compose() {
  docker compose -p "$COSMOSYS_SHARED_DB_PROJECT" \
    --env-file "$COSMOSYS_SHARED_DB_ENV_FILE" \
    -f "$deployment_repository_dir/shared-db/compose.yml" "$@"
}

proxy_compose() {
  docker compose -p "$proxy_project" \
    --env-file "$COSMOSYS_PROXY_ENV_FILE" \
    -f "$deployment_repository_dir/proxy/compose.yml" "$@"
}

instance_compose() {
  (
    COSMOSYS_ENV_FILE=$instance_env
    export COSMOSYS_ENV_FILE
    deployment_compose "$@"
  )
}

cleanup() {
  cleanup_failed=0
  if [ -f "$instance_env" ]; then
    instance_compose down --volumes --remove-orphans >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [ -f "$COSMOSYS_PROXY_ENV_FILE" ]; then
    proxy_compose down --volumes --remove-orphans >/dev/null 2>&1 || cleanup_failed=1
  fi
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

cat >"$COSMOSYS_PROXY_ENV_FILE" <<EOF
COSMOSYS_PROXY_NETWORK=csys_proxy_validation_$suffix
COSMOSYS_PROXY_BIND_ADDRESS=127.0.0.1
COSMOSYS_PROXY_HTTP_PORT=0
COSMOSYS_PROXY_HTTPS_PORT=0
COSMOSYS_PROXY_TLS=internal
EOF

https_status() {
  curl --silent --insecure --output /dev/null --write-out '%{http_code}' --max-time 10 \
    --resolve "$1:$https_port:127.0.0.1" "https://$1:$https_port/" || true
}

wait_for_route() {
  route_attempt=0
  while :; do
    route_status=$(https_status "$public_host")
    case "$1" in
      present) [ "$route_status" = 200 ] && return 0 ;;
      absent) [ "$route_status" != 200 ] && return 0 ;;
      blocked) [ "$route_status" = 403 ] && return 0 ;;
    esac
    route_attempt=$((route_attempt + 1))
    if [ "$route_attempt" -ge 45 ]; then
      echo "The route for $public_host is not $1 (last status $route_status)" >&2
      proxy_compose logs --no-color --tail 40 caddy >&2 || true
      return 1
    fi
    sleep 2
  done
}

echo "Starting reverse proxy validation as $proxy_project..."
shared_compose up -d --wait postgres
proxy_compose up -d --wait

https_port=$(proxy_compose port caddy 443)
https_port=${https_port##*:}
http_port=$(proxy_compose port caddy 80)
http_port=${http_port##*:}

if "$provision" --tls internal "orphan_$suffix" "$validation_directory/orphan.env" >/dev/null 2>&1; then
  echo "Provisioning accepted --tls without --hostname" >&2
  exit 1
fi
if "$provision" --hostname "$public_host" --tls 'not an address' "invalid_$suffix" \
  "$validation_directory/invalid.env" >/dev/null 2>&1; then
  echo "Provisioning accepted an invalid --tls value" >&2
  exit 1
fi

"$provision" --hostname "$public_host" "$instance" "$instance_env" >/dev/null
for env_line in \
  "COSMOSYS_PROXY_MODE=shared" \
  "COSMOSYS_HOSTNAME=$public_host" \
  "COSMOSYS_PROXY_TLS=internal" \
  "COSMOSYS_PROXY_NETWORK=csys_proxy_validation_$suffix" \
  "COSMOSYS_HTTP_PORT=0"; do
  if ! grep -qxF "$env_line" "$instance_env"; then
    echo "Instance environment lacks $env_line" >&2
    exit 1
  fi
done

if ! instance_compose up -d --wait --build redmine; then
  instance_compose logs --no-color --tail 100 migrate bootstrap redmine >&2 || true
  exit 1
fi

wait_for_route present

redirect=$(curl --silent --output /dev/null --write-out '%{http_code} %{redirect_url}' --max-time 10 \
  --resolve "$public_host:$http_port:127.0.0.1" "http://$public_host:$http_port/" || true)
case "$redirect" in
  "308 https://$public_host"*) ;;
  *)
    echo "Unexpected HTTP response for $public_host: $redirect" >&2
    exit 1
    ;;
esac

if [ "$(https_status "$unknown_host")" = 200 ]; then
  echo "The proxy served an unknown host name" >&2
  exit 1
fi

instance_compose exec -T redmine bundle exec rails runner \
  "abort(\"host_name is #{Setting.host_name}\") unless Setting.host_name == '$public_host'; abort(\"protocol is #{Setting.protocol}\") unless Setting.protocol == 'https'"

caddy_container=$(proxy_compose ps -q caddy)
if docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' "$caddy_container" | grep -q docker.sock; then
  echo "The internet-facing proxy mounts the Docker socket" >&2
  exit 1
fi

docker_api_container=$(proxy_compose ps -q docker-api)
docker_api_addresses=$(docker inspect \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$docker_api_container")
for docker_api_target in docker-api "${proxy_project}-docker-api-1" $docker_api_addresses; do
  if instance_compose exec -T redmine ruby -rsocket -rtimeout -e \
    "Timeout.timeout(5) { TCPSocket.new('$docker_api_target', 2375) }" >/dev/null 2>&1; then
    echo "The instance can reach the Docker API at $docker_api_target" >&2
    exit 1
  fi
done

# Overlays of the host that block address ranges at the proxy. Each one names
# its own matcher and numbers its respond directive, because Compose merges
# labels by key: with two plain caddy.respond labels only the last one would
# survive, and the first block would vanish without an error. private_ranges
# covers this client, which reaches the proxy through Docker; 192.0.2.0/24 is
# a documentation range that never does.
write_block_overlay() {
  cat >"$validation_directory/overlays/$1.yml" <<EOF
services:
  redmine:
    labels:
      caddy.@validation_$1.remote_ip: $2
      caddy.respond_$3: "@validation_$1 403"
EOF
}

echo "Checking that two overlays of the host block address ranges together..."
mkdir "$validation_directory/overlays"
write_block_overlay first private_ranges 1
write_block_overlay second 192.0.2.0/24 2
echo "COSMOSYS_COMPOSE_OVERLAYS=overlays/first.yml,overlays/second.yml" >>"$instance_env"
instance_compose up -d --wait redmine
wait_for_route blocked

write_block_overlay first 192.0.2.0/24 1
write_block_overlay second private_ranges 2
instance_compose up -d --wait redmine
wait_for_route blocked

sed '/^COSMOSYS_COMPOSE_OVERLAYS=/d' "$instance_env" >"$validation_directory/instance.env.new"
cat "$validation_directory/instance.env.new" >"$instance_env"
instance_compose up -d --wait redmine
wait_for_route present

instance_compose stop redmine >/dev/null
wait_for_route absent

echo "Reverse proxy validation passed."
