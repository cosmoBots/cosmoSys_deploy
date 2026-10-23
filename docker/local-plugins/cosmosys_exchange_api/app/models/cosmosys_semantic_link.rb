class CosmosysSemanticLink < ActiveRecord::Base
 belongs_to :source,class_name:'Issue'
 belongs_to :target,class_name:'Issue'
 belongs_to :author,class_name:'User'
 validates :status,inclusion:{in:%w[proposed approved rejected]}
 validates :provenance,presence:true,length:{maximum:4000}
 validates :predicate,uniqueness:{scope:[:source_id,:target_id]}
end
