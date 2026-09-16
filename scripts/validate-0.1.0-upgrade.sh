#!/bin/sh
set -eu

# Reproduce the supported database transition from the released 0.1.0 plugin
# pair to the 0.1.1 candidate pinned by deploy/compose*.yml. The stack and its
# named volumes are disposable and isolated from every development instance.

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
validation_project="csys_upgrade_validation_$$"
compose_files="-f $repository_dir/compose.yml -f $repository_dir/compose.requirements.yml"

baseline_cosmosys_revision=ff0d71e76d3f4e759e8405f120da9285930772f5
baseline_requirements_revision=31f9aaf527c258b127c3e429c36b3a4c9e411b29
candidate_cosmosys_revision=${COSMOSYS_011_REVISION:-c1f2be8586d8951de8148b80d57fbed809c621bf}
candidate_requirements_revision=${COSMOSYS_REQ_011_REVISION:-b5d979573a35cb65abc9ad9b1b6c861c3eb07470}

export POSTGRES_PASSWORD="upgrade-validation-database-password-$$"
export REDMINE_SECRET_KEY_BASE="upgrade-validation-secret-key-base-$$"
export COSMOSYS_INITIAL_ADMIN_PASSWORD="upgrade-validation-admin-password-$$"
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

select_release() {
  release=$1
  case "$release" in
    010)
      export COSMOSYS_REVISION=$baseline_cosmosys_revision
      export COSMOSYS_REQ_REVISION=$baseline_requirements_revision
      export COSMOSYS_IMAGE="cosmobots/cosmosys-upgrade-validation:0.1.0-$$"
      export COSMOSYS_REQ_IMAGE="cosmobots/cosmosys-req-upgrade-validation:0.1.0-$$"
      ;;
    011)
      export COSMOSYS_REVISION=$candidate_cosmosys_revision
      export COSMOSYS_REQ_REVISION=$candidate_requirements_revision
      export COSMOSYS_IMAGE="cosmobots/cosmosys-upgrade-validation:0.1.1-$$"
      export COSMOSYS_REQ_IMAGE="cosmobots/cosmosys-req-upgrade-validation:0.1.1-$$"
      ;;
  esac
}

echo "Building and starting the exact 0.1.0 baseline..."
select_release 010
compose build redmine migrate bootstrap
compose up -d --wait redmine

compose exec -T redmine bundle exec rails runner "
  versions = %i[cosmosys cosmosys_req].to_h { |key| [key, Redmine::Plugin.find(key).version.to_s] }
  abort(%Q[unexpected baseline versions: #{versions.inspect}]) unless versions.values == %w[0.1.0 0.1.0]
  admin = User.find_by_login('admin') || User.active.order(:id).first!
  project = Project.create!(
    name: 'cosmoSys 0.1.0 upgrade fixture',
    identifier: 'cosmosys-010-upgrade-fixture',
    cscode: 'UPGRADE',
    csys_project_profile: 'requirements',
    is_public: false
  )
  project.enabled_module_names = (project.enabled_module_names + %w[issue_tracking]).uniq
  tracker = Tracker.find_by!(csys_key: 'requirement')
  project.trackers << tracker unless project.trackers.exists?(tracker.id)
  issue = Issue.new(
    project: project,
    tracker: tracker,
    status: tracker.default_status || IssueStatus.order(:position, :id).first!,
    author: admin,
    subject: 'Legacy variable source',
    description: 'The throughput shall be \${AverageThroughput.value}.',
    rq_var: 'AverageThroughput',
    rq_value: '85%'
  )
  issue.save!
  Setting.plugin_cosmosys = Setting.plugin_cosmosys.merge(
    'upgrade_validation_issue_id' => issue.id.to_s,
    'upgrade_validation_issue_csid' => issue.csid
  )
  puts %Q[Seeded issue #{issue.id} (#{issue.csid})]
"

echo "Replacing application images with the 0.1.1 candidate while retaining volumes..."
compose stop redmine >/dev/null
select_release 011
compose build redmine migrate bootstrap
compose up -d --wait --force-recreate redmine

compose exec -T redmine bundle exec rails runner "
  versions = %i[cosmosys cosmosys_req].to_h { |key| [key, Redmine::Plugin.find(key).version.to_s] }
  abort(%Q[unexpected candidate versions: #{versions.inspect}]) unless versions.values == %w[0.1.1 0.1.1]

  settings = Setting.plugin_cosmosys
  source = Issue.find(settings.fetch('upgrade_validation_issue_id').to_i)
  abort('source issue CSID changed') unless source.csid == settings.fetch('upgrade_validation_issue_csid')
  abort('source issue disappeared') unless source.subject == 'Legacy variable source'
  abort('legacy rq_var survived') if Issue.column_names.include?('rq_var')
  abort('legacy rq_value survived') if Issue.column_names.include?('rq_value')

  datum = Issue.joins(:tracker).find_by!(
    project_id: source.project_id,
    csid: 'AverageThroughput',
    trackers: { csys_item_kind: 'datum' }
  )
  abort('datum value was not migrated') unless datum.csys_value == '85%'
  abort('datum provenance was not migrated') unless datum.csys_datum_source_issue_id == source.id
  abort('datum has no generated metadata section') unless datum.parent&.tracker&.csys_item_kind == 'data_section'

  base_versions = ActiveRecord::Base.connection.select_values(
    %q[SELECT version FROM schema_migrations WHERE version LIKE '%-cosmosys' ORDER BY version]
  )
  req_versions = ActiveRecord::Base.connection.select_values(
    %q[SELECT version FROM schema_migrations WHERE version LIKE '%-cosmosys_req' ORDER BY version]
  )
  expected_base = (1..8).map { |number| %Q[#{number}-cosmosys] }
  expected_req = (1..4).map { |number| %Q[#{number}-cosmosys_req] }
  abort(%Q[unexpected cosmosys migrations: #{base_versions.inspect}]) unless base_versions == expected_base
  abort(%Q[unexpected cosmosys_req migrations: #{req_versions.inspect}]) unless req_versions == expected_req
"

compose exec -T redmine bundle exec rake db:migrate:status >/dev/null
compose exec -T redmine ruby -rnet/http -e \
  "response = Net::HTTP.get_response(URI('http://127.0.0.1:3000/')); abort(response.code) unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)"

echo "0.1.0 -> 0.1.1 upgrade validation passed."
cleanup
trap - EXIT HUP INT TERM
