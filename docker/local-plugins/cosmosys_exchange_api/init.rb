require 'redmine'
Redmine::Plugin.register :cosmosys_exchange_api do
 name 'cosmoSys Exchange API'
 author 'Desarrollo local de Fran'
 description 'Extensión local: intercambio reversible y relaciones tipadas'
 version '0.2.0'
 menu :project_menu,:cosmosys_semantic,{controller:'cosmosys_semantic',action:'index'},caption:'Relaciones',param: :project_id,permission:false,if:proc{|p|p&.visible?(User.current)}
end
TEXT_BRIDGE_LIBRARY=true unless defined?(TEXT_BRIDGE_LIBRARY)
require_dependency File.expand_path('lib/text_bridge',__dir__)
require_dependency File.expand_path('app/models/cosmosys_semantic_entity',__dir__)
require_dependency File.expand_path('app/models/cosmosys_semantic_link',__dir__)
require_dependency File.expand_path('lib/cosmosys_semantic_graph',__dir__)
