#!/bin/sh
set -eu

variant=${1:-all}

case "$variant" in
  base|requirements|all) ;;
  *)
    echo "Usage: $0 [base|requirements|all]" >&2
    exit 2
    ;;
esac

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

validate_variant() {
  selected_variant=$1
  validation_project="csys_deploy_validation_${selected_variant}_$$"
  compose_files="-f $repository_dir/compose.yml"
  expected_plugins="cosmosys"

  if [ "$selected_variant" = requirements ]; then
    compose_files="$compose_files -f $repository_dir/compose.requirements.yml"
    expected_plugins="cosmosys cosmosys_req"
  fi

  export POSTGRES_PASSWORD="validation-database-password-$$"
  export REDMINE_SECRET_KEY_BASE="validation-secret-key-base-$$"
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
  if ! compose up -d --wait redmine; then
    echo "Migration and startup logs for $selected_variant:" >&2
    compose logs --no-color --tail 200 migrate redmine >&2 || true
    return 1
  fi

  compose exec -T redmine bundle exec rails runner \
    "expected = %w[$expected_plugins]; actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); missing = expected - actual; abort(\"Missing plugins: #{missing.join(', ')}\") unless missing.empty?; abort('cosmosys_req unexpectedly loaded') if expected == ['cosmosys'] && actual.include?('cosmosys_req')"
  compose exec -T redmine bundle exec rails runner \
    "public_help = Project.find_by(identifier: 'csys_help'); admin_help = Project.find_by(identifier: 'csys_admin_help'); abort('missing public help') unless public_help&.is_public?; abort('missing private admin help') unless admin_help && !admin_help.is_public?; abort('missing help pages') unless public_help.wiki.find_page('csInt_Overview', with_redirect: false) && public_help.wiki.find_page('Overview', with_redirect: false); abort('missing managed registry') unless Setting.where(name: 'cosmosys_managed_content_registry').exists?"

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
else
  validate_variant "$variant"
fi
