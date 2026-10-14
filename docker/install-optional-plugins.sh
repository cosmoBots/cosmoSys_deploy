#!/bin/sh
set -eu

# Build step: fetches every optional plugin of the catalog at its pinned
# revision into /opt/cosmosys/plugins-available, outside plugins/, and moves
# their Gemfiles into Gemfile.local under one Bundler group per plugin. Their
# gems are installed with the image, but the Gemfile stays the same whichever
# plugins an instance activates, and only active groups are required.

deploy_dir=/opt/cosmosys-deploy
catalog="$deploy_dir/plugins.conf"
available=/opt/cosmosys/plugins-available
gemfiles=/opt/cosmosys/gemfiles

. "$deploy_dir/catalog-lib.sh"

mkdir -p "$available" "$gemfiles"
: >Gemfile.local
: >"$deploy_dir/plugin-revisions"

for plugin in $(catalog_all_plugins "$catalog"); do
  source=$(catalog_value "$catalog" "PLUGIN_${plugin}_SOURCE")
  revision=$(catalog_value "$catalog" "PLUGIN_${plugin}_REVISION")
  subdir=$(catalog_value "$catalog" "PLUGIN_${plugin}_SUBDIR")
  local_dir=$(catalog_value "$catalog" "PLUGIN_${plugin}_LOCAL")
  target="$available/$plugin"

  if [ -n "$local_dir" ]; then
    # The Dockerfile copies local plugins in place before this step.
    if [ ! -d "$target" ]; then
      echo "Local plugin $plugin was not copied to $target" >&2
      exit 1
    fi
    revision=local
  else
    case "$revision" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
      *)
        echo "Plugin $plugin has no immutable revision in the catalog" >&2
        exit 1
        ;;
    esac
    if [ "${#revision}" -ne 40 ] || [ -z "$source" ]; then
      echo "Plugin $plugin needs a source and a 40-character revision" >&2
      exit 1
    fi
    checkout="/tmp/cosmosys-plugin-$plugin"
    git clone --quiet --filter=blob:none "$source" "$checkout"
    git -C "$checkout" checkout --quiet "$revision"
    test "$(git -C "$checkout" rev-parse HEAD)" = "$revision"
    if [ -n "$subdir" ]; then
      cp -a "$checkout/$subdir" "$target"
    else
      cp -a "$checkout" "$target"
    fi
    rm -rf "$checkout" "$target/.git"
  fi

  if [ ! -f "$target/init.rb" ]; then
    echo "Plugin $plugin has no init.rb in $target" >&2
    exit 1
  fi

  for gemfile in Gemfile PluginGemfile; do
    if [ -f "$target/$gemfile" ]; then
      mv "$target/$gemfile" "$gemfiles/$plugin-$gemfile.rb"
      printf 'group :cosmosys_%s do\n  eval_gemfile %s\nend\n' \
        "$plugin" "'$gemfiles/$plugin-$gemfile.rb'" >>Gemfile.local
    fi
  done
  rm -f "$target/Gemfile.lock"

  printf '%s=%s\n' "$plugin" "$revision" >>"$deploy_dir/plugin-revisions"
done
