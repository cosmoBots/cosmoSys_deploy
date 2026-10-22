RedmineApp::Application.routes.draw do
 get 'projects/:project_id/semantic',to:'cosmosys_semantic#index'
 post 'projects/:project_id/semantic/types',to:'cosmosys_semantic#set_type'
 post 'projects/:project_id/semantic/links',to:'cosmosys_semantic#save_link'
 get 'projects/:project_id/exchange/v1/snapshot',to:'cosmosys_exchange#snapshot',defaults:{format:'json'}
 post 'projects/:project_id/exchange/v1/changes',to:'cosmosys_exchange#changes',defaults:{format:'json'}
 post 'projects/:project_id/exchange/v1/nodes',to:'cosmosys_exchange#create_node',defaults:{format:'json'}
end
