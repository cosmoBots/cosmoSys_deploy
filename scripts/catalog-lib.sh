#!/bin/sh

# Reads plugins.conf, the catalog of optional plugins. The deployment scripts
# and the image share this file, so an instance is validated against the same
# rules on the host and inside its container. Lists are space-separated words.

# Prints the value of KEY in the catalog FILE, or nothing.
catalog_value() {
  sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

# Prints WORD once for each word of the list, in order, dropping repetitions.
catalog_unique() {
  catalog_unique_seen=' '
  for catalog_unique_word in $1; do
    case "$catalog_unique_seen" in
      *" $catalog_unique_word "*) ;;
      *)
        catalog_unique_seen="$catalog_unique_seen$catalog_unique_word "
        printf '%s\n' "$catalog_unique_word"
        ;;
    esac
  done
}

# Prints the options of an instance setting such as "kroki,latex" in the
# canonical order of the catalog. Unknown options are an error.
catalog_options() {
  catalog_options_requested=$(printf '%s' "$2" | tr ',' ' ')
  catalog_options_known=$(catalog_value "$1" COSMOSYS_OPTIONS)

  for catalog_options_name in $catalog_options_requested; do
    case " $catalog_options_known " in
      *" $catalog_options_name "*) ;;
      *)
        echo "Unknown optional plugin set '$catalog_options_name'; this deployment offers: $catalog_options_known" >&2
        return 2
        ;;
    esac
  done

  for catalog_options_name in $catalog_options_known; do
    case " $catalog_options_requested " in
      *" $catalog_options_name "*) printf '%s\n' "$catalog_options_name" ;;
    esac
  done
}

# Prints the plugins of a list of options, once each.
catalog_option_plugins() {
  catalog_option_plugins_all=
  for catalog_option_plugins_name in $2; do
    catalog_option_plugins_all="$catalog_option_plugins_all $(catalog_value "$1" "OPTION_${catalog_option_plugins_name}_PLUGINS")"
  done
  catalog_unique "$catalog_option_plugins_all"
}

# Prints the tool groups that a list of options needs, in canonical order.
catalog_option_tools() {
  catalog_option_tools_needed=
  for catalog_option_tools_name in $2; do
    catalog_option_tools_needed="$catalog_option_tools_needed $(catalog_value "$1" "OPTION_${catalog_option_tools_name}_TOOLS")"
  done
  for catalog_option_tools_group in $(catalog_value "$1" COSMOSYS_TOOL_GROUPS); do
    case " $catalog_option_tools_needed " in
      *" $catalog_option_tools_group "*) printf '%s\n' "$catalog_option_tools_group" ;;
    esac
  done
}

# Prints a setting such as "mathtext nbconvert" as tool groups in canonical
# order. Unknown groups are an error.
catalog_tools() {
  catalog_tools_requested=$(printf '%s' "$2" | tr ',' ' ')
  catalog_tools_known=$(catalog_value "$1" COSMOSYS_TOOL_GROUPS)

  for catalog_tools_group in $catalog_tools_requested; do
    case " $catalog_tools_known " in
      *" $catalog_tools_group "*) ;;
      *)
        echo "Unknown tool group '$catalog_tools_group'; this deployment offers: $catalog_tools_known" >&2
        return 2
        ;;
    esac
  done

  for catalog_tools_group in $catalog_tools_known; do
    case " $catalog_tools_requested " in
      *" $catalog_tools_group "*) printf '%s\n' "$catalog_tools_group" ;;
    esac
  done
}

# Prints the overlays with services that a list of options adds.
catalog_option_compose_files() {
  for catalog_option_compose_name in $2; do
    catalog_value "$1" "OPTION_${catalog_option_compose_name}_COMPOSE"
  done | sed '/^$/d'
}

# Prints the instance settings that pin the service images of a list of
# options.
catalog_option_pins() {
  catalog_option_pins_all=
  for catalog_option_pins_name in $2; do
    catalog_option_pins_all="$catalog_option_pins_all $(catalog_value "$1" "OPTION_${catalog_option_pins_name}_PINS")"
  done
  catalog_unique "$catalog_option_pins_all"
}

# Prints every plugin of every option, once each.
catalog_all_plugins() {
  catalog_option_plugins "$1" "$(catalog_value "$1" COSMOSYS_OPTIONS)"
}

# Prints the Debian packages of a list of tool groups.
catalog_tool_packages() {
  catalog_tool_packages_all=
  for catalog_tool_packages_group in $2; do
    catalog_tool_packages_all="$catalog_tool_packages_all $(catalog_value "$1" "TOOLS_${catalog_tool_packages_group}_APT")"
  done
  catalog_unique "$catalog_tool_packages_all"
}

# Joins the lines on standard input with SEPARATOR.
catalog_join() {
  paste -sd "$1" -
}
