#!/bin/sh
set -eu

# Starts disposable instances from the images this checkout builds and checks
# them: one per variant and set of optional plugins. Every instance of a
# variant shares the layers of one image, and only the tools of LaTeX and
# similar sets add a last layer of their own.
#
#   scripts/validate-deployment.sh all
#   scripts/validate-deployment.sh requirements kroki,latex

. "$(dirname -- "$0")/deployment-lib.sh"

usage() {
  echo "Usage: $0 [all | base|requirements [SET[,SET...]]]" >&2
}

# Everything comes from the environment files generated below.
unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDMINE_SECRET_KEY_BASE \
  COSMOSYS_INITIAL_ADMIN_PASSWORD COSMOSYS_INITIAL_ADMIN_PASSWORD_FILE \
  COSMOSYS_HTTP_PORT COSMOSYS_DB_MODE COSMOSYS_PROXY_MODE COSMOSYS_VARIANT \
  COSMOSYS_PLUGINS COSMOSYS_TOOLS COSMOSYS_IMAGE COSMOSYS_REQ_IMAGE \
  COSMOSYS_KROKI_ENABLED COSMOSYS_LATEX_ENABLED COSMOSYS_NOTEBOOK_PREVIEW_ENABLED \
  COSMOSYS_PORIS_ENABLED COMPOSE_PROJECT_NAME COSMOSYS_COMPOSE_OVERLAYS

validation_directory=$(mktemp -d)
trap 'rm -rf "$validation_directory"' EXIT
case_number=0

validate_case() {
  selected_variant=$1
  plugins=$(catalog_options "$deployment_catalog" "${2:-}") || return 2
  tools=$(catalog_option_tools "$deployment_catalog" "$plugins")
  active_plugins=$(catalog_option_plugins "$deployment_catalog" "$plugins" | catalog_join ' ')
  plugins=$(printf '%s\n' "$plugins" | catalog_join ,)
  tools=$(printf '%s\n' "$tools" | catalog_join ,)
  case_number=$((case_number + 1))
  description="$selected_variant with ${plugins:-no optional plugins}"

  image=$(deployment_image_with_tools "$(sh "$deployment_repository_dir/scripts/image-tag.sh" "$selected_variant")" "$tools")
  image_setting=COSMOSYS_IMAGE
  expected_plugins=cosmosys
  if [ "$selected_variant" = requirements ]; then
    image_setting=COSMOSYS_REQ_IMAGE
    expected_plugins="cosmosys cosmosys_req"
  fi
  expected_plugins="$expected_plugins $active_plugins"
  dormant_plugins=
  for plugin in $(catalog_all_plugins "$deployment_catalog"); do
    case " $active_plugins " in
      *" $plugin "*) ;;
      *) dormant_plugins="$dormant_plugins $plugin" ;;
    esac
  done
  absent_packages=
  absent_python_packages=
  for tool in $(catalog_value "$deployment_catalog" COSMOSYS_TOOL_GROUPS); do
    case ",$tools," in
      *",$tool,"*) ;;
      *)
        absent_packages="$absent_packages $(catalog_value "$deployment_catalog" "TOOLS_${tool}_APT")"
        absent_python_packages="$absent_python_packages $(catalog_value "$deployment_catalog" "TOOLS_${tool}_PYTHON")"
        ;;
    esac
  done

  export COSMOSYS_ENV_FILE="$validation_directory/case-$case_number.env"
  export COSMOSYS_COMPOSE_PROJECT="csys_deploy_validation_${case_number}_$$"
  cat >"$COSMOSYS_ENV_FILE" <<EOF
COSMOSYS_VARIANT=$selected_variant
COSMOSYS_PLUGINS=$plugins
COSMOSYS_TOOLS=$tools
$image_setting=$image
POSTGRES_PASSWORD=validation-database-password-$$
REDMINE_SECRET_KEY_BASE=validation-secret-key-base-$$
COSMOSYS_INITIAL_ADMIN_PASSWORD=validation-admin-password-$$
COSMOSYS_HTTP_PORT=0
EOF

  compose() {
    deployment_compose "$@"
  }
  runner() {
    compose exec -T redmine bundle exec rails runner "$1"
  }

  cleanup_case() {
    if [ "${KEEP_VALIDATION_STACK:-0}" = 1 ]; then
      echo "Keeping $COSMOSYS_COMPOSE_PROJECT for inspection ($COSMOSYS_ENV_FILE)."
      trap - EXIT
    elif ! compose down --volumes --remove-orphans >/dev/null 2>&1; then
      echo "Warning: could not remove $COSMOSYS_COMPOSE_PROJECT; remove it by hand." >&2
    fi
  }
  trap 'cleanup_case; rm -rf "$validation_directory"' EXIT HUP INT TERM

  echo "Validating $description as $COSMOSYS_COMPOSE_PROJECT ($image)..."
  compose config --quiet
  if ! compose up --build -d --wait redmine; then
    echo "Migration and startup logs for $description:" >&2
    compose logs --no-color --tail 200 migrate bootstrap redmine >&2 || true
    return 1
  fi

  # Exactly the plugins of the variant and of the active sets are registered.
  runner "expected = %w[$expected_plugins].select { |plugin| File.read(File.join('plugins', plugin, 'init.rb')).include?('Plugin.register') }; actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s); abort(\"registered plugins: #{actual.sort.join(', ')}; expected: #{expected.sort.join(', ')}\") unless actual.sort == expected.sort"

  # Dormant plugins stay out of plugins/ and their gems stay unloaded.
  runner "dormant = %w[$dormant_plugins]; present = dormant.select { |plugin| File.exist?(File.join('plugins', plugin)) }; abort(\"dormant plugins in plugins/: #{present.join(', ')}\") unless present.empty?; loaded = \$LOADED_FEATURES.join(\"\\n\"); Bundler.definition.dependencies.each { |dependency| owners = dormant.select { |plugin| dependency.groups.include?(:\"cosmosys_#{plugin}\") }; next if owners.empty? || dependency.groups.include?(:default); abort(\"#{dependency.name} of dormant #{owners.join(', ')} is loaded\") if loaded.include?(\"/gems/#{dependency.name}-\") }"

  # The Gemfile is the one the image was built with, whatever is active, so
  # the official entrypoint never installs gems when the container starts.
  pristine_gemfiles=$(docker run --rm --entrypoint sha256sum "$image" Gemfile Gemfile.lock </dev/null)
  running_gemfiles=$(compose exec -T redmine sha256sum Gemfile Gemfile.lock)
  if [ "$pristine_gemfiles" != "$running_gemfiles" ]; then
    echo "The Gemfile of $description differs from the one of its image:" >&2
    printf '%s\n%s\n' "$pristine_gemfiles" "$running_gemfiles" >&2
    return 1
  fi
  compose exec -T redmine bundle check >/dev/null

  # One asset of every active plugin that has assets is served.
  runner "require 'net/http'; %w[$active_plugins].each { |plugin| assets = File.join('plugins', plugin, 'assets'); next unless File.directory?(assets); file = Dir.glob(File.join(assets, '*', '**', '*')).sort.find { |path| File.file?(path) && !File.basename(path).start_with?('.') }; next unless file; logical = File.join('plugin_assets', plugin, file.split('/')[4..].join('/')); path = ActionController::Base.helpers.asset_path(logical); response = Net::HTTP.get_response(URI(\"http://127.0.0.1:3000#{path}\")); abort(\"#{plugin}: #{logical} answered #{response.code} at #{path}\") unless response.is_a?(Net::HTTPSuccess) }"

  # Tools of the sets that are not active are not in the image at all.
  for package in $absent_packages; do
    if compose exec -T redmine dpkg -s "$package" >/dev/null 2>&1; then
      echo "$description carries $package, which none of its plugin sets needs." >&2
      return 1
    fi
  done
  if [ -z "$tools" ] && compose exec -T redmine test -e /opt/cosmosys-python; then
    echo "$description carries /opt/cosmosys-python, which none of its plugin sets needs." >&2
    return 1
  fi
  for package in $absent_python_packages; do
    if compose exec -T redmine /opt/cosmosys-python/bin/pip show "$package" >/dev/null 2>&1; then
      echo "$description carries the Python package $package, which none of its plugin sets needs." >&2
      return 1
    fi
  done
  compose exec -T redmine sh -c 'test ! -e /opt/cosmosys-python || /opt/cosmosys-python/bin/pip check' >/dev/null

  # Every migration of every registered plugin is applied.
  runner "Redmine::Plugin.all.each { |plugin| migrations = Dir.glob(File.join(plugin.directory, 'db', 'migrate', '*.rb')).size; next if migrations.zero?; applied = ActiveRecord::Base.connection.select_value(\"SELECT COUNT(*) FROM schema_migrations WHERE version LIKE '%-#{plugin.id}'\").to_i; abort(\"#{plugin.id}: #{applied} of #{migrations} migrations applied\") unless applied == migrations }"

  case ",$plugins," in
    *,adr,*)
      # An ADR in a project with the ADRs module: numbered, dated when it is
      # accepted, locked once decided, and referenced from a second ADR.
      runner "tracker = CosmosysAdr.tracker; abort('the csAdr tracker is missing') unless tracker; missing = CosmosysAdr::STATUS_KEYS.reject { |key| CosmosysAdr.status(key) }; abort(\"ADR statuses are missing: #{missing.join(', ')}\") unless missing.empty?; abort('the adr item kind is not registered by cosmosys_adr') unless Cosmosys::ItemKindRegistry.registered?('adr') && Cosmosys::ItemKindRegistry.fetch('adr').provider == :cosmosys_adr; admin = User.find_by_login('admin'); User.current = admin; project = Project.new(name: 'ADR deploy check', identifier: 'adr-deploy-check', cscode: 'ADRCHK'); project.csys_modules_explicit = '1'; project.enabled_module_names = %w[issue_tracking adrs]; project.save!; abort('the ADRs module did not add the csAdr tracker') unless project.reload.trackers.include?(tracker); decision = Issue.find(Issue.create!(project: project, tracker: tracker, author: admin, subject: 'Deploy check decision').id); abort(\"the first ADR is #{decision.cosmosys_adr_label.inspect}, not ADR-0001\") unless decision.cosmosys_adr_label == 'ADR-0001' && decision.cosmosys_adr_status_key == :proposed; decision.init_journal(admin); decision.status = CosmosysAdr.status(:accepted); decision.save!; decision = Issue.find(decision.id); abort('accepting the ADR did not date the decision') unless decision.cosmosys_adr_status_key == :accepted && decision.adr_date; decision.subject = 'Changed after the decision'; abort('an accepted ADR can still be changed') if decision.save; Issue.create!(project: project, tracker: tracker, author: admin, subject: 'Deploy check follow-up', description: 'Follows ADR#1.')"
      # The ADRs tab lists both, and the page of the second one links the
      # first from its description.
      runner "require 'net/http'; project = Project.find_by!(identifier: 'adr-deploy-check'); decision, follow_up = project.issues.where.not(adr_number: nil).order(:adr_number).to_a; http = Net::HTTP.new('127.0.0.1', 3000); cookies = lambda { |response| response.get_fields('Set-Cookie').to_a.map { |cookie| cookie[/\\A[^;]+/] }.join('; ') }; login = http.get('/login'); token = login.body[/name=\"authenticity_token\" value=\"([^\"]+)\"/, 1]; signed_in = http.post('/login', URI.encode_www_form(username: 'admin', password: ENV.fetch('COSMOSYS_INITIAL_ADMIN_PASSWORD'), authenticity_token: token), 'Cookie' => cookies.call(login)); abort(\"signing in answered #{signed_in.code}\") unless signed_in.is_a?(Net::HTTPRedirection) && !signed_in['Location'].to_s.include?('/login'); session = {'Cookie' => cookies.call(signed_in)}; tab = http.get(\"/projects/#{project.identifier}/adrs\", session); abort(\"the ADRs tab answered #{tab.code}\") unless tab.is_a?(Net::HTTPSuccess); %w[ADR-0001 ADR-0002].each { |label| abort(\"the ADRs tab does not list #{label}\") unless tab.body.include?(label) }; page = http.get(\"/issues/#{follow_up.id}\", session); abort(\"the page of ADR-0002 answered #{page.code}\") unless page.is_a?(Net::HTTPSuccess); description = page.body[%r{id=\"issue_description_wiki\".*?</div>}m].to_s; abort('ADR#1 is not rendered as a link to ADR-0001') unless description.include?(\"href=\\\"/issues/#{decision.id}\\\" class=\\\"cosmosys-adr-ref\")"
      ;;
  esac
  case ",$plugins," in
    *,kroki,*)
      runner "abort('Kroki compatibility initializer not loaded') unless Setting.singleton_class.ancestors.include?(RedmineKrokiSettingsCompatibility::SettingPatch); Setting.plugin_redmine_kroki = {'kroki_url' => 'http://kroki:8000'}; settings = Setting.plugin_redmine_kroki; abort('Kroki settings do not support symbol access') unless settings[:kroki_url] == 'http://kroki:8000'; abort('Kroki settings lost string access') unless settings['kroki_url'] == 'http://kroki:8000'; abort('cosmoSys Kroki report-export patch not loaded') unless Cosmosys::ItemsController.ancestors.include?(CosmosysKroki::ItemsControllerPatch); abort('cosmoSys Kroki macro patch not loaded') unless Redmine::WikiFormatting::Macros::Definitions.ancestors.include?(CosmosysKroki::MacroDefinitionsPatch)"
      runner "require 'net/http'; response = Net::HTTP.post(URI('http://kroki:8000/graphviz/svg'), 'digraph G { A -> B }', 'Content-Type' => 'text/plain'); abort(\"Kroki returned #{response.code}\") unless response.is_a?(Net::HTTPSuccess)"
      ;;
  esac
  case ",$plugins," in
    *,latex,*|*,notebooks,*)
      runner "abort('Redmine Cbots LaTeX renderer is not loaded') unless defined?(RedmineCbotsLatex::LatexRenderer); python = Setting.plugin_redmine_cbots_latex['python_bin']; abort(\"LaTeX uses #{python}, not #{ENV['LATEX_PYTHON_BIN']}\") unless python == ENV['LATEX_PYTHON_BIN']; abort('matplotlib is unavailable') unless system(python, '-c', 'import matplotlib', out: File::NULL, err: File::NULL); require 'tmpdir'; rendered = RedmineCbotsLatex::LatexRenderer.render_html('<p>\\(x^2\\)</p>', cache_dir: Dir.mktmpdir); abort('static LaTeX rendering did not produce an image') unless rendered.include?('data:image/png;base64,')"
      ;;
  esac
  case ",$plugins," in
    *,notebooks,*)
      # A notebook with a markdown formula and a plotted image goes through
      # the viewer as an attachment would: converted for the page, then
      # prepared for a static export, where the formula becomes an image.
      runner "require 'json'; pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='; notebook = {'cells' => [{'cell_type' => 'markdown', 'metadata' => {}, 'source' => ['Deploy check \$x^2\$']}, {'cell_type' => 'code', 'execution_count' => 1, 'metadata' => {}, 'source' => ['plot()'], 'outputs' => [{'output_type' => 'display_data', 'metadata' => {}, 'data' => {'image/png' => pixel, 'text/plain' => ['<Figure>']}}]}], 'metadata' => {'language_info' => {'name' => 'python'}}, 'nbformat' => 4, 'nbformat_minor' => 5}; settings = Setting.plugin_redmine_notebook_preview; abort(\"the viewer runs #{settings['jupyter_bin']}, not #{ENV['JUPYTER_BIN']}\") unless settings['jupyter_bin'] == ENV['JUPYTER_BIN']; attachment = Attachment.new(file: JSON.generate(notebook), filename: 'deploy-check.ipynb', author: User.where(admin: true).first); attachment.save!; service = RedmineNotebookPreview::NbconvertService; status = service.convert(attachment); abort(\"conversion failed: #{service.cached_error(attachment.id)}\") unless status == :ok; html = service.cached_html(attachment.id).to_s; abort('the preview lacks the text or the plotted image') unless html.include?('Deploy check') && html.include?('data:image/png'); exported = service.prepare_for_export(html); abort('the formula was not turned into an image for export') unless exported.scan('data:image/png').size > html.scan('data:image/png').size; attachment.destroy"
      ;;
  esac
  case ",$plugins," in
    *,poris,*)
      runner "require 'json'; kinds = %w[poris_sys poris_param poris_mode poris_value poris_cmd]; abort('the poris project profile is not registered') unless Cosmosys::ProjectProfileRegistry.registered?('poris'); missing = kinds.reject { |kind| Cosmosys::ItemKindRegistry.registered?(kind) }; abort(\"PORIS item kinds are not registered: #{missing.join(', ')}\") unless missing.empty?; abort('the PORIS trackers are missing') unless Tracker.where(csys_key: kinds).count == kinds.size; viewer = Rails.root.join('plugins/cosmosys_poris/assets/javascripts/poris_viewer'); bundle = viewer.join('prod.js'); abort('the PORIS viewer bundle is missing') unless bundle.file? && bundle.size > 100_000 && viewer.join('style.css').file?; abort('the PORIS viewer bundle needs Node: it refers to process.env') if bundle.read.match?(/process\\.env/); abort('the PORIS viewer bundle does not record its porisViewer revision') unless JSON.parse(viewer.join('build-info.json').read)['revision'].to_s.match?(/\\A[0-9a-f]{40}\\z/)"
      # A private PORIS project with a parameter, a mode enabling a float value
      # and its precedes relation: the viewer page loads the bundle, and its
      # configuration tab, asked for with the session, embeds a model that
      # describes those items.
      runner "require 'net/http'; require 'json'; admin = User.find_by_login('admin'); User.current = admin; trackers = Tracker.where(csys_key: %w[poris_sys poris_param poris_mode poris_value]).index_by(&:csys_key); project = Project.create!(name: 'PORIS deploy check', identifier: 'poris-deploy-check', cscode: 'PORISCHK', csys_project_profile: 'poris', is_public: false); item = lambda { |key, subject, parent, attributes = {}| Issue.create!({project: project, tracker: trackers.fetch(key), author: admin, subject: subject, parent_issue_id: parent&.id}.merge(attributes)) }; root = item.call('poris_sys', 'Check system', nil); parameter = item.call('poris_param', 'Check parameter', root); mode = item.call('poris_mode', 'Check mode', parameter); value = item.call('poris_value', 'Check value', parameter, pr_value_kind: 'float', pr_min: 0, pr_default: 1, pr_max: 2); IssueRelation.create!(issue_from: mode, issue_to: value, relation_type: 'precedes'); http = Net::HTTP.new('127.0.0.1', 3000); cookies = lambda { |response| response.get_fields('Set-Cookie').to_a.map { |cookie| cookie[/\\A[^;]+/] }.join('; ') }; login = http.get('/login'); token = login.body[/name=\"authenticity_token\" value=\"([^\"]+)\"/, 1]; signed_in = http.post('/login', URI.encode_www_form(username: 'admin', password: ENV.fetch('COSMOSYS_INITIAL_ADMIN_PASSWORD'), authenticity_token: token), 'Cookie' => cookies.call(login)); abort(\"signing in answered #{signed_in.code}\") unless signed_in.is_a?(Net::HTTPRedirection) && !signed_in['Location'].to_s.include?('/login'); session = {'Cookie' => cookies.call(signed_in)}; page = http.get(\"/projects/#{project.identifier}/poris\", session); abort(\"the PORIS viewer page answered #{page.code}\") unless page.is_a?(Net::HTTPSuccess) && page.body.include?('porisViewer'); bundle_path = page.body[%r{'([^']*/poris_viewer/prod[^']*\\.js)'}, 1]; abort('the PORIS viewer page does not load the bundle') unless bundle_path; bundle = http.get(bundle_path); abort(\"the PORIS viewer bundle answered #{bundle.code} at #{bundle_path}\") unless bundle.is_a?(Net::HTTPSuccess) && bundle.body.bytesize > 100_000; tab_path = page.body[/data-initial-url=\"([^\"]+)\"/, 1]; abort('the PORIS viewer page does not name its configuration tab') unless tab_path; tab = http.get(tab_path, session); abort(\"the PORIS configuration tab answered #{tab.code} at #{tab_path}\") unless tab.is_a?(Net::HTTPSuccess); embedded = tab.body[%r{class=\"poris-project-model-xml\">(.*?)</script>}m, 1]; abort('the PORIS configuration tab does not embed the model') unless embedded; model = JSON.parse(embedded); ['Check system', 'Check parameter', 'Check mode', 'Check value'].each { |name| abort(\"the PORIS model lacks #{name}\") unless model.include?(\"<name>#{name}</name>\") }; abort('the PORIS model lacks the range of the value') unless model.include?('<rangemax type=\"float\">2')"
      ;;
  esac
  case ",$plugins," in
    *,cad,*)
      runner /opt/cosmosys-deploy/bootstrap/verify_cad.rb
      ;;
  esac
  case ",$plugins," in
    *,tags,*)
      runner "page = Project.find_by!(identifier: 'csys_help').wiki.find_page('Overview', with_redirect: false); page.tag_list = 'deploy-check'; page.save!; abort('the tag was not stored') unless WikiPage.find(page.id).tag_list.include?('deploy-check'); abort('the tagged page is not found by its tag') unless WikiPage.tagged_with('deploy-check').exists?(page.id); abort('no tag in the tags table') unless AdditionalTag.where(name: 'deploy-check').exists?"
      ;;
  esac

  runner "public_help = Project.find_by(identifier: 'csys_help'); admin_help = Project.find_by(identifier: 'csys_admin_help'); abort('missing public help') unless public_help&.is_public?; abort('missing private admin help') unless admin_help && !admin_help.is_public?; abort('missing help pages') unless public_help.wiki.find_page('csInt_Overview', with_redirect: false) && public_help.wiki.find_page('Overview', with_redirect: false); abort('missing managed registry') unless Setting.where(name: 'cosmosys_managed_content_registry').exists?"
  runner "admin = User.active.find_by_login('admin'); abort('initial admin password not configured') unless admin&.check_password?(ENV.fetch('COSMOSYS_INITIAL_ADMIN_PASSWORD')); abort('admin still forced to change password') if admin.must_change_passwd?"

  if [ "$selected_variant" = base ] && [ -z "$plugins" ]; then
    runner "wiki = Project.find_by!(identifier: 'csys_help').wiki; facade = wiki.find_page('Overview', with_redirect: false); facade.content.update!(text: 'Administrator customization'); internal = wiki.find_page('csInt_Overview', with_redirect: false); internal.content.update!(text: 'Unsupported managed customization')"
    compose run --rm bootstrap >/dev/null
    runner "wiki = Project.find_by!(identifier: 'csys_help').wiki; abort('facade overwritten') unless wiki.find_page('Overview', with_redirect: false).content.text == 'Administrator customization'; abort('managed page not restored') unless wiki.find_page('csInt_Overview', with_redirect: false).content.text.include?('cosmoSys help')"

    # The entrypoint refuses what this image cannot run.
    for refused in nonexistent "$(catalog_value "$deployment_catalog" COSMOSYS_OPTIONS | tr ' ' '\n' |
      while read -r option; do [ -n "$(catalog_value "$deployment_catalog" "OPTION_${option}_TOOLS")" ] && echo "$option"; done | head -n 1)"; do
      [ -n "$refused" ] || continue
      if docker run --rm -e COSMOSYS_PLUGINS="$refused" "$image" true </dev/null >/dev/null 2>&1; then
        echo "The entrypoint of $image accepted COSMOSYS_PLUGINS=$refused." >&2
        return 1
      fi
    done
  fi
  compose exec -T redmine bundle exec rake db:migrate:status >/dev/null
  compose exec -T redmine ruby -rnet/http -e \
    "response = Net::HTTP.get_response(URI('http://127.0.0.1:3000/')); abort(response.code) unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)"
  compose exec -T redmine sh -c \
    "test -w /usr/src/redmine/files && command -v dot >/dev/null && command -v rsvg-convert >/dev/null && command -v libreoffice >/dev/null"

  echo "$description deployment validation passed."
  cleanup_case
  trap 'rm -rf "$validation_directory"' EXIT
  trap - HUP INT TERM
}

case "${1:-all}" in
  all)
    # Each set once, every set together on each variant, and nothing.
    validate_case base ''
    for option in $(catalog_value "$deployment_catalog" COSMOSYS_OPTIONS); do
      validate_case base "$option"
    done
    validate_case requirements ''
    validate_case requirements "$(catalog_value "$deployment_catalog" COSMOSYS_OPTIONS | tr ' ' ',')"
    ;;
  base|requirements)
    validate_case "$1" "${2:-}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
