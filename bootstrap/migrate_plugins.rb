# frozen_string_literal: true

# Redmine sorts plugin migrations by ID, not dependency. Architecture's
# workflow seed needs Requirements, which must in turn follow cosmoSys.
first = %i[cosmosys cosmosys_req]
first.each do |id|
  Redmine::Plugin.find(id).migrate if Redmine::Plugin.installed?(id)
end
Redmine::Plugin.all.reject { |plugin| first.include?(plugin.id.to_sym) }.each(&:migrate)

# Match redmine:plugins:migrate: the final schema must include plugin changes,
# not just the Redmine schema dumped by the preceding db:migrate command.
require 'rake'
Rails.application.load_tasks unless Rake::Task.task_defined?('db:schema:dump')
Rake::Task['db:schema:dump'].invoke
