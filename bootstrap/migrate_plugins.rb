# frozen_string_literal: true

# Redmine sorts plugin migrations by ID, not dependency. Architecture's
# workflow seed needs Requirements, which must in turn follow cosmoSys.
first = %i[cosmosys cosmosys_req]
first.each do |id|
  Redmine::Plugin.find(id).migrate if Redmine::Plugin.installed?(id)
end
Redmine::Plugin.all.reject { |plugin| first.include?(plugin.id.to_sym) }.each(&:migrate)
