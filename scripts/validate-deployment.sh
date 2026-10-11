#!/bin/sh
set -eu

variant=${1:-all}

case "$variant" in
  base|requirements|all|base-kroki|requirements-kroki) ;;
  *)
    echo "Usage: $0 [base|requirements|all|base-kroki|requirements-kroki]" >&2
    exit 2
    ;;
esac

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

validate_variant() {
  selected_variant=$1
  kroki_enabled=${2:-false}
  validation_project="csys_deploy_validation_${selected_variant}_$$"
  compose_files="-f $repository_dir/compose.yml"
  expected_plugins="cosmosys"

  if [ "$selected_variant" = requirements ]; then
    compose_files="$compose_files -f $repository_dir/compose.requirements.yml"
    expected_plugins="cosmosys cosmosys_req"
  fi

  if [ "$kroki_enabled" = true ]; then
    compose_files="$compose_files -f $repository_dir/compose.kroki.yml"
    if [ "$selected_variant" = requirements ]; then
      compose_files="$compose_files -f $repository_dir/compose.requirements-kroki.yml"
    fi
    expected_plugins="$expected_plugins redmine_kroki cosmosys_kroki"
  fi

  export POSTGRES_PASSWORD="validation-database-password-$$"
  export REDMINE_SECRET_KEY_BASE="validation-secret-key-base-$$"
  export COSMOSYS_INITIAL_ADMIN_PASSWORD="validation-admin-password-$$"
  export COSMOSYS_HTTP_PORT=0

  compose() {
    # shellcheck disable=SC2086
    docker compose -p "$validation_project" $compose_files "$@"
  }

  cleanup() {
    if [ "${KEEP_VALIDATION_STACK:-0}" = 1 ]; then
      echo "Keeping $validation_project for inspection."
    else
      compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT HUP INT TERM

  echo "Validating $selected_variant as isolated Compose project $validation_project..."
  compose config --quiet
  if ! compose up --build -d --wait redmine; then
    echo "Migration and startup logs for $selected_variant:" >&2
    compose logs --no-color --tail 200 migrate redmine >&2 || true
    return 1
  fi

  compose exec -T redmine bundle exec rails runner \
    "expected = %w[$expected_plugins]; actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); missing = expected - actual; abort(\"Missing plugins: #{missing.join(', ')}\") unless missing.empty?; abort('cosmosys_req unexpectedly loaded') if actual.include?('cosmosys_req') && !expected.include?('cosmosys_req')"
  if [ "$kroki_enabled" = true ]; then
    compose exec -T redmine bundle exec rails runner \
      "abort('Kroki compatibility initializer not loaded') unless Setting.singleton_class.ancestors.include?(RedmineKrokiSettingsCompatibility::SettingPatch); Setting.plugin_redmine_kroki = {'kroki_url' => 'http://kroki:8000'}; settings = Setting.plugin_redmine_kroki; abort('Kroki settings do not support symbol access') unless settings[:kroki_url] == 'http://kroki:8000'; abort('Kroki settings lost string access') unless settings['kroki_url'] == 'http://kroki:8000'; abort('cosmoSys Kroki report-export patch not loaded') unless Cosmosys::ItemsController.ancestors.include?(CosmosysKroki::ItemsControllerPatch); abort('cosmoSys Kroki macro patch not loaded') unless Redmine::WikiFormatting::Macros::Definitions.ancestors.include?(CosmosysKroki::MacroDefinitionsPatch)"
    compose exec -T redmine bundle exec rails runner \
      "require 'net/http'; response = Net::HTTP.post(URI('http://kroki:8000/graphviz/svg'), 'digraph G { A -> B }', 'Content-Type' => 'text/plain'); abort(\"Kroki returned #{response.code}\") unless response.is_a?(Net::HTTPSuccess)"
  fi
  compose exec -T redmine bundle exec rails runner \
    "public_help = Project.find_by(identifier: 'csys_help'); admin_help = Project.find_by(identifier: 'csys_admin_help'); abort('missing public help') unless public_help&.is_public?; abort('missing private admin help') unless admin_help && !admin_help.is_public?; abort('missing help pages') unless public_help.wiki.find_page('csInt_Overview', with_redirect: false) && public_help.wiki.find_page('Overview', with_redirect: false); abort('missing managed registry') unless Setting.where(name: 'cosmosys_managed_content_registry').exists?"
  compose exec -T redmine bundle exec rails runner \
    "admin = User.active.find_by_login('admin'); abort('initial admin password not configured') unless admin&.check_password?(ENV.fetch('COSMOSYS_INITIAL_ADMIN_PASSWORD')); abort('admin still forced to change password') if admin.must_change_passwd?"

  if [ "$selected_variant" = base ]; then
    compose exec -T redmine bundle exec rails runner \
      "wiki = Project.find_by!(identifier: 'csys_help').wiki; facade = wiki.find_page('Overview', with_redirect: false); facade.content.update!(text: 'Administrator customization'); internal = wiki.find_page('csInt_Overview', with_redirect: false); internal.content.update!(text: 'Unsupported managed customization')"
    compose run --rm bootstrap >/dev/null
    compose exec -T redmine bundle exec rails runner \
      "wiki = Project.find_by!(identifier: 'csys_help').wiki; abort('facade overwritten') unless wiki.find_page('Overview', with_redirect: false).content.text == 'Administrator customization'; abort('managed page not restored') unless wiki.find_page('csInt_Overview', with_redirect: false).content.text.include?('cosmoSys help')"
  fi
  compose exec -T redmine bundle exec rake db:migrate:status >/dev/null
  compose exec -T redmine ruby -rnet/http -e \
    "response = Net::HTTP.get_response(URI('http://127.0.0.1:3000/')); abort(response.code) unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)"
  compose exec -T redmine sh -c \
    "test -w /usr/src/redmine/files && command -v dot >/dev/null && command -v rsvg-convert >/dev/null && command -v libreoffice >/dev/null"

  echo "$selected_variant deployment validation passed."
  cleanup
  trap - EXIT HUP INT TERM
}

if [ "$variant" = all ]; then
  validate_variant base
  validate_variant requirements
elif [ "$variant" = base-kroki ]; then
  validate_variant base true
elif [ "$variant" = requirements-kroki ]; then
  validate_variant requirements true
else
  validate_variant "$variant"
fi
