#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/deployment-lib.sh"

deployment_compose exec -T redmine \
  bundle exec rails runner plugins/cosmosys/scripts/audit_issue_trees.rb -- --notify-admins "$@"
