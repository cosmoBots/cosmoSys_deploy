# frozen_string_literal: true

# Evaluated by config/application.rb before the initializers and the plugins
# run. The gems of every optional plugin are installed under one Bundler group
# per plugin, which Bundler.require(*Rails.groups) leaves alone; this requires
# only the groups of the plugins the cosmoSys entrypoint copied into plugins/.
active_plugins_file = '/opt/cosmosys-deploy/active-plugins'
if File.file?(active_plugins_file)
  active_groups = File.readlines(active_plugins_file, chomp: true).reject(&:empty?).map { |plugin| :"cosmosys_#{plugin}" }
  Bundler.require(*active_groups) unless active_groups.empty?
end
