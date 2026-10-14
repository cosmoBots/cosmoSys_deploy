#!/bin/sh
set -eu

# Last build step: installs the tool groups an instance needs, such as
# matplotlib for LaTeX. Debian packages come from apt, and Python packages go
# into one virtual environment, /opt/cosmosys-python, from the pinned and
# hashed requirements in docker/python/<group>.txt. Instances without those
# options get an image without them. The groups installed are recorded so that
# the entrypoint refuses an option whose tools this image lacks.

deploy_dir=/opt/cosmosys-deploy
catalog="$deploy_dir/plugins.conf"
python_env=/opt/cosmosys-python

. "$deploy_dir/catalog-lib.sh"

tools=$(catalog_tools "$catalog" "${1:-}")
packages=$(catalog_tool_packages "$catalog" "$tools")
python_groups=$(catalog_python_groups "$catalog" "$tools")
if [ -n "$python_groups" ]; then
  packages="$packages python3-venv"
fi

if [ -n "$(printf '%s' "$packages" | tr -d '[:space:]')" ]; then
  apt-get -o Acquire::Retries=5 update
  # shellcheck disable=SC2086
  apt-get -o Acquire::Retries=5 install -y --no-install-recommends $packages
  rm -rf /var/lib/apt/lists/*
fi

# Every requirements file pins the whole dependency closure of its group with
# hashes, so pip resolves nothing and downloads only the files it lists.
if [ -n "$python_groups" ]; then
  python3 -m venv "$python_env"
  for group in $python_groups; do
    "$python_env/bin/pip" install --no-cache-dir --disable-pip-version-check \
      --no-deps --require-hashes --only-binary :all: \
      -r "$deploy_dir/python/$group.txt"
  done
  "$python_env/bin/pip" check
fi

printf '%s\n' $tools >"$deploy_dir/tools"
