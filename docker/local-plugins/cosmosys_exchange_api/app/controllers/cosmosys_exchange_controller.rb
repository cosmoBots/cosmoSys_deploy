class CosmosysExchangeController < ApplicationController
 accept_api_auth :snapshot,:changes,:create_node
 before_action :require_login
 before_action :find_project_by_project_id
 before_action :prepare_engine
 rescue_from TextBridge::Conflict,ActiveRecord::StaleObjectError do |e|
  render json:{error:e.message},status: :conflict
 end
 rescue_from ActiveRecord::RecordInvalid,ArgumentError,KeyError do |e|
  render json:{error:e.message},status: :unprocessable_entity
 end

 def snapshot
  data=ActiveRecord::Base.transaction(isolation: :repeatable_read){@engine.snapshot}
  render json:data
 end
 def changes
  raise ArgumentError,'Payload too large' if request.content_length.to_i>25_000_000
  data=params.require(:changes).map{|c|c.to_unsafe_h}
  render json:@engine.apply(data,dry_run:params[:dry_run]==true)
 end
 def create_node
  raise Unauthorized unless User.current.allowed_to?(:add_issues,@project)
  token=params.require(:token).to_s
  raise ArgumentError,'Invalid idempotency key' unless token.match?(/\A[0-9a-f-]{36}\z/)
  title=params.require(:title).to_s
  raise ArgumentError,'Invalid title' unless title.length.between?(1,255) && title.strip.present?
  marker="Gestores independientes: alta #{token}"
  result=nil
  ActiveRecord::Base.transaction do
   @project.lock!
   old=Issue.visible(User.current).where(project_id:@project.id).joins(:journals).find_by(journals:{notes:marker})
   parent=params[:parent].present? ? Issue.visible(User.current).where(project_id:@project.id).find(Integer(params[:parent])) : nil
   if old
    raise ArgumentError,'Idempotency key used for another operation' unless old.subject==title && old.parent_id==parent&.id
    result={key:"issue:#{old.id}",created:false}
   else
    tracker=parent&.tracker || @project.trackers.find_by(name:'csInfo') || @project.trackers.first!
    position=@project.issues.where(parent_id:parent&.id).maximum(:csposition).to_i+1
    item=Issue.new(project:@project,tracker:tracker,author:User.current,subject:title,description:'',parent_issue_id:parent&.id,csposition:position)
    raise Unauthorized unless item.safe_attribute?('subject',User.current) && (!parent || item.safe_attribute?('parent_issue_id',User.current))
    item.save!;item.update_columns(csposition:position)
    item.journals.create!(user:User.current,notes:marker)
    templates={
      'story'=>['Capítulo 1','Capítulo 2'],
      'script'=>['Acto 1','Acto 2','Acto 3'],
      'series'=>['Episodio 1','Episodio 2'],
      'paper'=>['Resumen','Introducción','Método','Resultados','Discusión','Referencias'],
      'tfg'=>['Resumen','Introducción y pregunta de investigación','Objetivos','Marco teórico','Método','Resultados','Discusión','Conclusiones','Referencias','Anexos']}
    template=params[:template].to_s
    raise ArgumentError,'Unknown template' unless template.empty? || templates.key?(template)
    Array(templates[template]).each_with_index do |label,index|
      child=Issue.create!(project:@project,tracker:tracker,author:User.current,subject:label,description:'',parent_issue_id:item.id,csposition:index+1)
      child.update_columns(csposition:index+1)
    end
    result={key:"issue:#{item.id}",created:true}
   end
   raise ActiveRecord::Rollback if params[:dry_run]==true
  end
  render json:result,status: :created
 end
 private
 def prepare_engine
  raise Unauthorized unless @project.visible?(User.current)
  @engine=TextBridge.new(@project.identifier,user:User.current)
 end
end
