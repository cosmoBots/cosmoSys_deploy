class CreateCosmosysSemanticGraph < ActiveRecord::Migration[7.2]
 def change
  create_table :cosmosys_semantic_entities do |t|
   t.bigint :issue_id, null:false
   t.string :kind, null:false
   t.integer :lock_version, null:false, default:0
   t.timestamps
  end
  add_index :cosmosys_semantic_entities,:issue_id,unique:true
  add_foreign_key :cosmosys_semantic_entities,:issues,on_delete: :cascade
  create_table :cosmosys_semantic_links do |t|
   t.bigint :source_id,null:false
   t.bigint :target_id,null:false
   t.string :predicate,null:false
   t.string :status,null:false,default:'proposed'
   t.text :provenance,null:false
   t.bigint :author_id,null:false
   t.integer :lock_version,null:false,default:0
   t.timestamps
  end
  add_index :cosmosys_semantic_links,[:source_id,:target_id,:predicate],unique:true,name:'cs_semantic_unique_link'
  add_foreign_key :cosmosys_semantic_links,:issues,column: :source_id,on_delete: :cascade
  add_foreign_key :cosmosys_semantic_links,:issues,column: :target_id,on_delete: :cascade
  add_foreign_key :cosmosys_semantic_links,:users,column: :author_id
 end
end
