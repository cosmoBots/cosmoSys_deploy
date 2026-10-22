# Run through rails runner in a configured Redmine instance. All fixture writes roll back.
require 'minitest/autorun'
class SemanticGraphTest < Minitest::Test
 TEST_LOGIN=ENV.fetch('SEMANTIC_TEST_USER','semantic_editor')
 TEST_PROJECT=ENV.fetch('SEMANTIC_TEST_PROJECT','semantic-fixture')
 def test_http_contract_and_authentication
  user=User.find_by!(login:TEST_LOGIN)
  session=ActionDispatch::Integration::Session.new(Rails.application)
  session.get("/projects/#{TEST_PROJECT}/semantic.json")
  assert_includes [401,403],session.response.status
  headers={'X-Redmine-API-Key'=>user.api_key,'Accept'=>'application/json'}
  session.get("/projects/#{TEST_PROJECT}/semantic.json",headers:headers)
  assert_equal 200,session.response.status,session.response.body[0,300]
  assert JSON.parse(session.response.body)['rules'].key?('set_in')
  session.post("/projects/#{TEST_PROJECT}/semantic/types.json",params:{issue_id:0,kind:'universe',revision:-1},headers:headers)
  assert_equal 403,session.response.status
 end
 def test_types_relations_permissions_and_atomicity
  ActiveRecord::Base.transaction do
   user=User.find_by!(login:TEST_LOGIN);project=Project.find_by!(identifier:TEST_PROJECT)
   graph=CosmosysSemanticGraph.new(user,project)
   tracker=project.trackers.find_by(name:'csInfo') || project.trackers.first!
   make=->(title){Issue.create!(project:project,tracker:tracker,author:user,subject:title)}
   work=make.call('TEST work');world=make.call('TEST universe');unit=make.call('TEST unit');unit2=make.call('TEST unit 2');character=make.call('TEST character')
   [[work,'work'],[world,'universe'],[unit,'unit'],[unit2,'unit'],[character,'character']].each{|i,k|graph.set_type({'issue_id'=>i.id,'kind'=>k,'revision'=>-1})}
   edge=->(s,t,p,extra={}){graph.save_link({'source_id'=>s.id,'target_id'=>t.id,'predicate'=>p,'revision'=>-1,'provenance'=>'Isolated test','status'=>'proposed'}.merge(extra))}
   result=edge.call(work,world,'set_in');assert_equal 'proposed',result[:status]
   assert_raises(CosmosysSemanticGraph::Conflict){edge.call(work,world,'set_in')}
   assert_raises(CosmosysSemanticGraph::Invalid){edge.call(character,world,'set_in')}
   assert_raises(CosmosysSemanticGraph::Invalid){edge.call(work,work,'adapts')}
   assert_raises(CosmosysSemanticGraph::Invalid){edge.call(character,world,'belongs_to',{'status'=>'approved'})}
   edge.call(character,world,'belongs_to',{'status'=>'approved','confirm_approval'=>'1'})
   edge.call(unit,unit2,'part_of')
   assert_raises(CosmosysSemanticGraph::Invalid){edge.call(unit2,unit,'part_of')}
   assert_raises(CosmosysSemanticGraph::Invalid){edge.call(unit,work,'part_of')}
   assert_raises(CosmosysSemanticGraph::Invalid){graph.set_type({'issue_id'=>world.id,'kind'=>'character','revision'=>0})}
   assert_equal 'universe',CosmosysSemanticEntity.find_by!(issue_id:world.id).kind
   assert_raises(CosmosysSemanticGraph::Conflict){graph.set_type({'issue_id'=>world.id,'kind'=>'universe','revision'=>-1})}
   outsider=User.new(login:'semantic-test-outsider',firstname:'Test',lastname:'Reader',mail:'semantic-test@example.invalid')
   outsider.password='Temporary-testing-only-84!';outsider.password_confirmation=outsider.password;outsider.save!
   assert_raises(CosmosysSemanticGraph::Forbidden){CosmosysSemanticGraph.new(outsider,project)} unless project.is_public?
   assert graph.snapshot[:links].any?{|l|l[:id]==result[:id]}
   raise ActiveRecord::Rollback
  end
 end
end
