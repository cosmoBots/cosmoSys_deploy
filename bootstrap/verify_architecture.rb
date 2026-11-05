# frozen_string_literal: true

abort('Architecture profile is absent') unless Cosmosys::ProjectProfileRegistry.registered?('architecture')
%w[arch_node arch_dof].each do |kind|
  abort("Missing #{kind} registration/tracker") unless Cosmosys::ItemKindRegistry.registered?(kind) && Tracker.exists?(csys_key: kind)
end
required = %w[arch_type arch_node_key arch_model_csid arch_cad_data arch_motion arch_axis arch_min arch_max arch_default arch_step]
abort('Architecture schema is incomplete') unless (required - Issue.column_names).empty?
directory = Redmine::Plugin.find(:cosmosys_arch).directory
abort('Architecture globally overrides CAD report tools') if File.exist?(File.join(directory, 'app/views/cosmosys_cad_embeds/_report_tools.html.erb'))
if Redmine::Plugin.installed?(:cosmosys_poris_arch)
  %w[cosmosys_poris_arch_bindings cosmosys_poris_arch_parameter_links cosmosys_poris_arch_command_policies].each do |table|
    abort("Missing #{table}") unless ActiveRecord::Base.connection.table_exists?(table)
  end
  index = ActiveRecord::Base.connection.indexes(:cosmosys_poris_arch_parameter_links).find { |entry| entry.name == 'idx_cpa_link_target' }
  abort('Parameter mapping index is incompatible') unless index&.unique && index.columns == %w[binding_id parameter_id dof_id]
  abort('PORIS runtime adapter is unavailable') unless defined?(CosmosysPoris::RuntimeExecutionAdapters) && defined?(CosmosysPorisArch::Dispatcher)
end
puts 'Architecture profiles/schema and optional PORIS bridge: PASS'
