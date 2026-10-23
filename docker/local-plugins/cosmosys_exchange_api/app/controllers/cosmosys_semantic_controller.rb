class CosmosysSemanticController < ApplicationController
 accept_api_auth :index,:set_type,:save_link
 before_action :require_login
 before_action :find_project_by_project_id
 before_action :engine
 rescue_from CosmosysSemanticGraph::Forbidden do |e|;failure(e,403);end
 rescue_from CosmosysSemanticGraph::Conflict,ActiveRecord::StaleObjectError do |e|;failure(e,409);end
 rescue_from CosmosysSemanticGraph::Invalid,ActiveRecord::RecordInvalid,KeyError,ArgumentError do |e|;failure(e,422);end
 def index
  @graph=@engine.snapshot
  respond_to do |format|
   format.json{render json:@graph}
   format.html
  end
 end
 def set_type;success(@engine.set_type(params.permit(:issue_id,:kind,:revision).to_h));end
 def save_link;success(@engine.save_link(params.permit(:source_id,:target_id,:predicate,:status,:provenance,:revision,:confirm_approval).to_h));end
 private
 def engine;@engine=CosmosysSemanticGraph.new(User.current,@project);end
 def success(result)
  respond_to do |format|
   format.json{render json:result}
   format.html{redirect_to action: :index,project_id:@project.identifier}
  end
 end
 def failure(error,status)
  respond_to do |format|
   format.json{render json:{error:error.message},status:status}
   format.html{@graph=@engine&.snapshot;flash.now[:error]=error.message;render :index,status:status}
  end
 end
end
