# Additive extension: issue contents and cosmoSys core are not modified.
class CosmosysSemanticGraph
 class Invalid < StandardError;end
 class Forbidden < StandardError;end
 class Conflict < StandardError;end
 TYPES=%w[universe character place event work unit track source policy collection].freeze
 RULES={
  'belongs_to'=>[%w[character place event],%w[universe]],
  'set_in'=>[%w[work],%w[universe]],
  'part_of'=>[%w[unit track],%w[work unit]],
  'features'=>[%w[unit],%w[character]],
  'depicts'=>[%w[unit track],%w[event]],
  'accompanies'=>[%w[track],%w[unit]],
  'adapts'=>[%w[work],%w[work]],
  'derived_from'=>[TYPES,%w[source]],
  'governed_by'=>[%w[work],%w[policy]],
  'groups'=>[%w[collection],%w[collection universe work]]
 }.freeze
 def initialize(user,project)
  @user,@project=user,project
  raise Forbidden,'Proyecto no accesible' unless project.visible?(user)
 end
 def issue(id,write:false)
  item=Issue.visible(@user).find_by(id:Integer(id))
  raise Forbidden,'Ficha no accesible' unless item
  raise Forbidden,'Sin permiso para editar la ficha' if write && (!@user.allowed_to?(:edit_issues,item.project) || !item.editable?(@user))
  item
 end
 def anchor(item)
  raise Invalid,'La ficha de origen no pertenece a este proyecto' unless item.project_id==@project.id
 end
 def transaction
  ActiveRecord::Base.transaction(requires_new:true) do
   # Serializes graph validation + mutation, including cyclic and type-change checks.
   ActiveRecord::Base.connection.execute('SELECT pg_advisory_xact_lock(72401926)')
   yield
  end
 end
 def expect_revision(record,value)
  raise Conflict,'La relación o el tipo ha cambiado; actualiza la página' unless Integer(value)==(record&.lock_version || -1)
 end
 def set_type(data)
  transaction do
   item=issue(data.fetch('issue_id'),write:true);anchor(item)
   kind=data.fetch('kind');raise Invalid,'Tipo desconocido' unless TYPES.include?(kind)
   old=CosmosysSemanticEntity.find_by(issue_id:item.id);expect_revision(old,data.fetch('revision'))
   record=old || CosmosysSemanticEntity.new(issue:item)
   record.kind=kind;record.save!
   CosmosysSemanticLink.where('source_id=? OR target_id=?',item.id,item.id).each{|link| validate_link(link)}
   audit(item,"Tipo semántico: #{kind}")
   {issue_id:item.id,kind:kind,revision:record.lock_version}
  end
 end
 def validate_link(link)
  raise Invalid,'Una ficha no puede relacionarse consigo misma' if link.source_id==link.target_id
  rule=RULES[link.predicate];raise Invalid,'Relación desconocida' unless rule
  types=CosmosysSemanticEntity.where(issue_id:[link.source_id,link.target_id]).pluck(:issue_id,:kind).to_h
  raise Invalid,'Tipos incompatibles o sin asignar' unless rule[0].include?(types[link.source_id]) && rule[1].include?(types[link.target_id])
  return if link.status=='rejected'
  if %w[part_of adapts groups].include?(link.predicate)
   edges=CosmosysSemanticLink.where(predicate:link.predicate).where.not(status:'rejected').where.not(id:link.id).pluck(:source_id,:target_id)
   graph=edges.group_by(&:first);queue=[link.target_id];seen={}
   until queue.empty?
    id=queue.pop;raise Invalid,'La relación crearía un ciclo' if id==link.source_id
    next if seen[id];seen[id]=true
    queue.concat(Array(graph[id]).map(&:last))
   end
  end
  if link.predicate=='part_of'
   other=CosmosysSemanticLink.where(source_id:link.source_id,predicate:'part_of').where.not(status:'rejected').where.not(id:link.id).exists?
   raise Invalid,'La unidad ya tiene un contenedor editorial activo' if other
  end
 end
 def save_link(data)
  transaction do
   src=issue(data.fetch('source_id'),write:true);anchor(src)
   dst=issue(data.fetch('target_id'),write:true)
   predicate=data.fetch('predicate')
   old=CosmosysSemanticLink.find_by(source_id:src.id,target_id:dst.id,predicate:predicate)
   expect_revision(old,data.fetch('revision'))
   link=old || CosmosysSemanticLink.new(source:src,target:dst,predicate:predicate,author:@user)
   link.status=data.fetch('status','proposed');link.provenance=data.fetch('provenance')
   # Explicit review is required to approve; importers never call this implicitly.
   raise Invalid,'Para aprobar marca la confirmación explícita' if link.status=='approved' && data['confirm_approval'].to_s!='1'
   validate_link(link);link.save!
   audit(src,"Relación semántica #{predicate} → ##{dst.id}: #{link.status}. Procedencia: #{link.provenance}")
   {id:link.id,revision:link.lock_version,status:link.status}
  end
 end
 def audit(item,note)
  # Cross-project target IDs must not leak through a source-only journal.
  journal=note.start_with?('Relación') ? 'Relación semántica actualizada. Consultar Relaciones para detalles sujetos a permisos.' : note
  item.journals.create!(user:@user,notes:journal)
 end
 def snapshot
  local=Issue.visible(@user).where(project_id:@project.id).pluck(:id)
  links=CosmosysSemanticLink.where('source_id IN (?) OR target_id IN (?)',local,local).to_a
  ids=(local+links.flat_map{|l|[l.source_id,l.target_id]}).uniq
  visible=Issue.visible(@user).where(id:ids).index_by(&:id)
  links.select!{|l|visible.key?(l.source_id)&&visible.key?(l.target_id)}
  kinds=CosmosysSemanticEntity.where(issue_id:visible.keys).index_by(&:issue_id)
  {types:TYPES,rules:RULES,nodes:visible.values.map{|i|{id:i.id,title:i.subject,project_id:i.project_id,kind:kinds[i.id]&.kind,revision:kinds[i.id]&.lock_version || -1}},links:links.map{|l|{id:l.id,source_id:l.source_id,target_id:l.target_id,predicate:l.predicate,status:l.status,provenance:l.provenance,revision:l.lock_version}}}
 end
end
