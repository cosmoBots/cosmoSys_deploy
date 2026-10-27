#!/bin/sh
# Run from any directory. Retains image, exited container, sources and logs.
set -eu
case "${1:-}" in
  ''|--package) ;;
  *) echo 'Usage: sh scripts/build-libredwg.sh [--package]' >&2; exit 2 ;;
esac
deploy_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
workspace=${LIBREDWG_WORKSPACE:-"$deploy_dir/../.local/toolchains/libredwg/0.14"}
mkdir -p "$workspace/downloads"
workspace=$(CDPATH='' cd -- "$workspace" && pwd)
archive="$workspace/downloads/libredwg-0.14.tar.xz"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 3 --connect-timeout 20 \
    https://ftp.gnu.org/gnu/libredwg/libredwg-0.14.tar.xz -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
echo "62ebb73b984f865960f20ed26619ea5f8789d5e3fd088fa40a2598384da81275  $archive" | sha256sum -c -
base=$(sed -n 's/^REDMINE_IMAGE=//p' "$deploy_dir/.env.example")
image=cosmosys-toolchain-libredwg:0.14-debian13
container=cosmosys-toolchain-libredwg-0.14
docker build --build-arg "REDMINE_IMAGE=$base" -t "$image" \
  -f "$deploy_dir/tools/libredwg/Dockerfile.builder" "$deploy_dir/tools/libredwg"
if docker container inspect "$container" >/dev/null 2>&1; then
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = false ] || {
    echo "The retained builder is already running: $container" >&2; exit 1;
  }
  retained_workspace=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}' "$container")
  [ "$retained_workspace" = "$workspace" ] || {
    echo "Retained builder uses $retained_workspace, not $workspace; refusing to mix builds." >&2; exit 1;
  }
  if [ "$(docker inspect -f '{{.Image}}' "$container")" != "$(docker image inspect -f '{{.Id}}' "$image")" ] ||
    [ "$(docker inspect -f '{{index .Config.Labels "eu.cosmobots.libredwg.recipe"}}' "$container")" != 2 ]; then
    # Keep previous failed/superseded environments too, rather than remove them.
    docker rename "$container" "$container-previous-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
fi
if ! docker container inspect "$container" >/dev/null 2>&1; then
  docker create --name "$container" --network none --user "$(id -u):$(id -g)" \
    --label eu.cosmobots.libredwg.recipe=2 \
    -e "LIBREDWG_BASE_IMAGE=$base" \
    -e "LIBREDWG_BUILDER_IMAGE=$(docker image inspect -f '{{.Id}}' "$image")" \
    --mount "type=bind,source=$workspace,target=/work" \
    --mount "type=bind,source=$deploy_dir/tools/libredwg,target=/recipe,readonly" \
    "$image" /recipe/compile.sh >/dev/null
fi
start_status=0
docker start -a "$container" || start_status=$?
status=$(docker inspect -f '{{.State.ExitCode}}' "$container")
[ "$start_status" -eq 0 ] || {
  echo "Builder failed to start or exited with error; preserved logs: $workspace/logs" >&2
  exit "$start_status"
}
[ "$status" -eq 0 ] || { echo "Build failed; preserved logs: $workspace/logs" >&2; exit "$status"; }
echo "Retained container: $container; image: $image; sources/build/logs: $workspace"
if [ "${1:-}" = --package ]; then
  destination="$deploy_dir/docker/tool-bundles/libredwg"
  for artifact in dwg2dxf COPYING BUILDINFO libredwg-0.14.tar.xz sample_2000.dwg SHA256SUMS; do
    cp "$workspace/output/$artifact" "$destination/$artifact"
  done
  echo "Packaged runtime bundle in $destination; review and validate before publishing."
fi
