#!/bin/sh

deployment_repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

deployment_compose() {
  if [ -n "${COSMOSYS_COMPOSE_PROJECT:-}" ]; then
    set -- -p "$COSMOSYS_COMPOSE_PROJECT" "$@"
  fi

  case "${COSMOSYS_VARIANT:-base}" in
    base)
      docker compose -f "$deployment_repository_dir/compose.yml" "$@"
      ;;
    requirements)
      docker compose -f "$deployment_repository_dir/compose.yml" \
        -f "$deployment_repository_dir/compose.requirements.yml" "$@"
      ;;
    *)
      echo "COSMOSYS_VARIANT must be base or requirements" >&2
      return 2
      ;;
  esac
}
