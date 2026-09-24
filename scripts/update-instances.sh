#!/bin/sh
set -eu

# Runs update-instance.sh over every instance of this host, one after another,
# and reports what happened to each. It adds no logic of its own: the options
# it receives are passed through unchanged, so each instance still decides for
# itself whether it updates unattended.

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
instances_directory=${COSMOSYS_INSTANCES_DIR:-}

usage() {
  cat >&2 <<EOF
Usage: COSMOSYS_INSTANCES_DIR=DIR $0 [options of update-instance.sh]

Runs update-instance.sh for every <name>.env file in DIR, in name order, and
prints one line per instance at the end. Every argument is passed through, so
--check reports the whole host and no argument updates the instances set to
auto while reporting the rest.

Instances are updated one after another on purpose: two builds at once fight
for the processor and for the build cache, while in sequence an instance that
declares the same versions as the previous one reuses the image it just built,
and two instances are never out of service at the same time.

An update that fails stops the run, because the version that broke one
instance is unlikely to be good for the next one. The instances left are
reported as not attempted.

Exit status: the most serious status of the instances, in this order: 1 an
update failed after changing something, 2 usage or configuration error, 3
refused, 4 another update was running, 10 an update is available, 0 nothing to
report.
EOF
}

if [ -z "$instances_directory" ]; then
  echo "Set COSMOSYS_INSTANCES_DIR to the directory holding the instance environment files" >&2
  usage
  exit 2
fi
if [ ! -d "$instances_directory" ]; then
  echo "Not a directory: $instances_directory" >&2
  exit 2
fi
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

# How serious each status is, to report the worst one of the host.
status_severity() {
  case "$1" in
    0) echo 0 ;;
    10) echo 1 ;;
    4) echo 2 ;;
    3) echo 3 ;;
    2) echo 4 ;;
    *) echo 5 ;;
  esac
}

status_description() {
  case "$1" in
    0) echo "up to date or updated" ;;
    10) echo "update available, not applied" ;;
    4) echo "another update is running" ;;
    3) echo "refused" ;;
    2) echo "usage or configuration error" ;;
    *) echo "the update failed" ;;
  esac
}

report_file=$(mktemp)
cleanup() {
  rm -f -- "$report_file"
}
trap cleanup EXIT HUP INT TERM

worst_status=0
worst_severity=0
instances_seen=0
stopped=0

for instance_env in "$instances_directory"/*.env; do
  [ -f "$instance_env" ] || continue
  instance_name=$(basename "$instance_env" .env)
  instances_seen=$((instances_seen + 1))

  if [ "$stopped" = 1 ]; then
    printf '%s\tnot attempted\n' "$instance_name" >>"$report_file"
    continue
  fi

  printf '\n===== %s =====\n' "$instance_name"
  instance_status=0
  COSMOSYS_ENV_FILE="$instance_env" \
    "$script_directory/update-instance.sh" "$@" || instance_status=$?

  printf '%s\t%s\n' "$instance_name" "$(status_description "$instance_status")" \
    >>"$report_file"

  instance_severity=$(status_severity "$instance_status")
  if [ "$instance_severity" -gt "$worst_severity" ]; then
    worst_severity=$instance_severity
    worst_status=$instance_status
  fi

  if [ "$instance_status" = 1 ]; then
    stopped=1
  fi
done

if [ "$instances_seen" = 0 ]; then
  echo "No instance environment file in $instances_directory" >&2
  exit 2
fi

printf '\n===== %s instances =====\n' "$instances_seen"
while IFS="$(printf '\t')" read -r reported_name reported_status; do
  printf '%-24s %s\n' "$reported_name" "$reported_status"
done <"$report_file"

if [ "$stopped" = 1 ]; then
  echo "The run stopped after a failed update; the instances left were not attempted." >&2
fi

exit "$worst_status"
