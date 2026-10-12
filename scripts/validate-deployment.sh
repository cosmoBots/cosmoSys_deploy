#!/bin/sh
set -eu

variant=${1:-all}

case "$variant" in
  base|requirements|all|base-kroki|requirements-kroki|requirements-kroki-latex|requirements-kroki-latex-notebook-preview|requirements-kroki-latex-notebook-preview-poris) ;;
  *)
    echo "Usage: $0 [base|requirements|all|base-kroki|requirements-kroki|requirements-kroki-latex|requirements-kroki-latex-notebook-preview|requirements-kroki-latex-notebook-preview-poris]" >&2
    exit 2
    ;;
esac

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

validate_variant() {
  selected_variant=$1
  kroki_enabled=${2:-false}
  latex_enabled=${3:-false}
  notebook_preview_enabled=${4:-false}
  poris_enabled=${5:-false}
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
  if [ "$latex_enabled" = true ]; then
    compose_files="$compose_files -f $repository_dir/compose.requirements-kroki-latex.yml"
    expected_plugins="$expected_plugins redmine_cbots_latex"
  fi
  if [ "$notebook_preview_enabled" = true ]; then
    compose_files="$compose_files -f $repository_dir/compose.requirements-kroki-latex-notebook-preview.yml"
    expected_plugins="$expected_plugins redmine_notebook_preview"
  fi
  if [ "$poris_enabled" = true ]; then
    compose_files="$compose_files -f $repository_dir/compose.requirements-kroki-latex-notebook-preview-poris.yml"
    expected_plugins="$expected_plugins cosmosys_poris"
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
  if [ "$poris_enabled" = true ]; then
    compose exec -T redmine bundle exec rails runner \
      "require 'json'; plugin = Redmine::Plugin.find(:cosmosys_poris); abort('cosmoSys PORIS plugin did not load') unless plugin; bundle = Rails.root.join('plugins/cosmosys_poris/assets/javascripts/poris_viewer/prod.js'); abort('PORIS viewer bundle is missing') unless File.file?(bundle) && File.size(bundle) > 100_000; metadata_path = bundle.dirname.join('build-info.json'); abort('PORIS viewer bundle metadata is missing') unless File.file?(metadata_path); metadata = JSON.parse(File.read(metadata_path)); abort('PORIS viewer source revision is invalid') unless metadata.fetch('revision').match?(/\\A[0-9a-f]{40}\\z/)"
  fi
  if [ "$kroki_enabled" = true ]; then
    compose exec -T redmine bundle exec rails runner \
      "abort('Kroki compatibility initializer not loaded') unless Setting.singleton_class.ancestors.include?(RedmineKrokiSettingsCompatibility::SettingPatch); Setting.plugin_redmine_kroki = {'kroki_url' => 'http://kroki:8000'}; settings = Setting.plugin_redmine_kroki; abort('Kroki settings do not support symbol access') unless settings[:kroki_url] == 'http://kroki:8000'; abort('Kroki settings lost string access') unless settings['kroki_url'] == 'http://kroki:8000'; abort('cosmoSys Kroki report-export patch not loaded') unless Cosmosys::ItemsController.ancestors.include?(CosmosysKroki::ItemsControllerPatch); abort('cosmoSys Kroki macro patch not loaded') unless Redmine::WikiFormatting::Macros::Definitions.ancestors.include?(CosmosysKroki::MacroDefinitionsPatch)"
    compose exec -T redmine bundle exec rails runner \
      "require 'net/http'; response = Net::HTTP.post(URI('http://kroki:8000/graphviz/svg'), 'digraph G { A -> B }', 'Content-Type' => 'text/plain'); abort(\"Kroki returned #{response.code}\") unless response.is_a?(Net::HTTPSuccess)"
  fi
  if [ "$latex_enabled" = true ]; then
    compose exec -T redmine bundle exec rails runner \
      "abort('Redmine Cbots LaTeX renderer is not loaded') unless defined?(RedmineCbotsLatex::LatexRenderer); abort('matplotlib is unavailable') unless system('/usr/bin/python3', '-c', 'import matplotlib', out: File::NULL, err: File::NULL); require 'tmpdir'; rendered = RedmineCbotsLatex::LatexRenderer.render_html('<p>\\(x^2\\)</p>', cache_dir: Dir.mktmpdir); abort('static LaTeX rendering did not produce an image') unless rendered.include?('data:image/png;base64,')"
  fi
  if [ "$notebook_preview_enabled" = true ]; then
    compose exec -T redmine bundle exec rails runner \
      "require 'open3'; require 'json'; settings = Setting.plugin_redmine_notebook_preview; jupyter = settings.fetch('jupyter_bin'); cache = settings.fetch('cache_dir'); abort('Jupyter is not executable') unless File.executable?(jupyter); abort('Notebook cache is not writable') unless File.directory?(cache) && File.writable?(cache); notebook = JSON.generate({'cells' => [{'cell_type' => 'markdown', 'metadata' => {}, 'source' => ['Notebook Preview deploy smoke test']}], 'metadata' => {'kernelspec' => {'display_name' => 'Python 3', 'language' => 'python', 'name' => 'python3'}, 'language_info' => {'name' => 'python'}}, 'nbformat' => 4, 'nbformat_minor' => 5}); html, error, status = Open3.capture3({'PYTHONIOENCODING' => 'utf-8'}, jupyter, 'nbconvert', '--to', 'html', '--template', 'basic', '--stdin', '--stdout', stdin_data: notebook); abort(\"nbconvert failed: #{error}\") unless status.success? && html.include?('Notebook Preview deploy smoke test')"
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
elif [ "$variant" = requirements-kroki-latex ]; then
  validate_variant requirements true true
elif [ "$variant" = requirements-kroki-latex-notebook-preview ]; then
  validate_variant requirements true true true
elif [ "$variant" = requirements-kroki-latex-notebook-preview-poris ]; then
  validate_variant requirements true true true true
else
  validate_variant "$variant"
fi
