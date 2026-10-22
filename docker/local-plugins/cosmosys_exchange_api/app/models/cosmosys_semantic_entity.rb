class CosmosysSemanticEntity < ActiveRecord::Base
 belongs_to :issue
 validates :issue_id,uniqueness:true
 validates :kind,inclusion:{in:%w[universe character place event work unit track source policy collection]}
end
