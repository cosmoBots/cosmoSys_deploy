#!/bin/sh
set -eu

# Last build step: installs the Debian packages of the tool groups an instance
# needs, such as matplotlib for LaTeX. Instances without those options get an
# image without those packages. The groups installed are recorded so that the
# entrypoint refuses an option whose tools this image lacks.

deploy_dir=/opt/cosmosys-deploy
catalog="$deploy_dir/plugins.conf"

. "$deploy_dir/catalog-lib.sh"

tools=$(catalog_tools "$catalog" "${1:-}")
packages=$(catalog_tool_packages "$catalog" "$tools")

if [ -n "$packages" ]; then
  apt-get -o Acquire::Retries=5 update
  # shellcheck disable=SC2086
  apt-get -o Acquire::Retries=5 install -y --no-install-recommends $packages
  rm -rf /var/lib/apt/lists/*
fi

printf '%s\n' $tools >"$deploy_dir/tools"
