#!/bin/sh
set -eu

. "$(dirname -- "$0")/deployment-lib.sh"

deployment_compose run --rm bootstrap
