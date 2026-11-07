# frozen_string_literal: true

# Shared, non-persistent check for disposable validation and instance updates.
require 'base64'
require 'net/http'
require 'open3'
require 'securerandom'
require 'tmpdir'

abort('CAD viewer is not loaded') unless defined?(RedmineCadPreview)
abort('CAD integration is not loaded') unless RedmineCadPreview::Macro.singleton_class < CosmosysCadPreview::ReportMacroPatch
abort('Obsolete CAD JSON store is loaded') if defined?(CosmosysCadPreview::ReportView)
abort('ImageMagick is unavailable for CAD figures') unless File.executable?('/usr/bin/magick')
abort('DWG converter is unavailable') unless RedmineCadPreview::DwgConverter.available?
abort('Upstream CAD view storage is absent') unless defined?(CadPreviewView) && CadPreviewView.table_exists?
abort('DWG converter is not server-managed') unless RedmineCadPreview::DwgConverter.command == '/usr/local/bin/dwg2dxf'
abort('DWG path is not configured on the server') unless Redmine::Configuration['dwg2dxf_command'] == '/usr/local/bin/dwg2dxf'
CosmosysCadPreview::UpstreamCompatibility.verify!(Redmine::Plugin.find(:redmine_cad_preview).version)
unsupported_rejected = false
begin
  CosmosysCadPreview::UpstreamCompatibility.verify!('1.2.0')
rescue Redmine::PluginRequirementError
  unsupported_rejected = true
end
abort('Unadapted upstream CAD release was accepted') unless unsupported_rejected

# A genuine upstream drawing, not the viewer's placeholder DWG fixtures.
# Fixture is copied unchanged from the corresponding sources shipped alongside
# it. Do not require an xz executable merely to run this runtime check.
Dir.mktmpdir('dwg-deploy-check-') do |directory|
  source = File.binread('/usr/local/share/doc/libredwg/sample_2000.dwg')
  input = File.join(directory, 'sample.dwg')
  output = File.join(directory, 'sample.dxf')
  File.binwrite(input, source)
  abort('Real DWG conversion failed') unless RedmineCadPreview::DwgConverter.convert(input, output)
  text = File.binread(output)
  abort('DWG conversion produced no DXF entities') unless text.include?('ENTITIES') && text.include?('EOF')
end

assets = {
  'redmine_cad_preview/cad_preview.js' => %w[getRenderContext cad-preview:ready cad-preview:error],
  'redmine_cad_preview/cad_preview.css' => %w[cad-preview-figure inline-block],
  'cosmosys_cad_preview/model_controls.js' => %w[cosmosys_cad_node_index]
}
assets.each do |asset, markers|
  path = ActionController::Base.helpers.asset_path("plugin_assets/#{asset}")
  response = Net::HTTP.get_response(URI("http://127.0.0.1:3000#{path}"))
  abort("CAD asset #{path} answered #{response.code}") unless response.is_a?(Net::HTTPSuccess)
  abort("CAD asset #{path} lacks its API") unless markers.all? { |marker| response.body.include?(marker) }
end
abort('CAD macro is not registered') unless Redmine::WikiFormatting::Macros.available_macros.keys.map(&:to_s).include?('cad_preview')

# Real validation/storage, but isolated files and no writes to project data.
previous_storage = Attachment.storage_path
previous_user = User.current
begin
  Dir.mktmpdir('cad-deploy-check-') do |directory|
    Attachment.storage_path = directory
    actor = User.active.find_by!(admin: true)
    User.current = actor
    state = { 'version' => 1, 'projection' => 'drawing', 'center' => [0, 0],
              'view_width' => 100, 'aspect' => 1.5 }
    png, error, result = Open3.capture3('/usr/bin/magick', '-size', '2x1', 'xc:#808080', 'png:-', binmode: true)
    abort("CAD figure generation failed: #{error}") unless result.success?
    Project.transaction do
      suffix = SecureRandom.hex(6)
      project = Project.create!(name: 'CAD deployment check', identifier: "cad-check-#{suffix}", cscode: "CAD#{suffix}", is_public: false)
      attachment = Attachment.create!(container: project, author: actor, file: "solid #{suffix}\nendsolid\n", filename: 'check.stl')
      store = RedmineCadPreview::Views
      first = store.save(attachment, 'front', user: actor, state: state, image: png)
      detail = store.save(attachment, 'detail', user: actor, state: state, image: png)
      raise 'CAD view save failed' unless first.persisted? && detail.persisted?
      raise 'CAD default view was overwritten' unless store.default(attachment).id == first.id
      raise 'CAD figure changed' unless File.binread(store.find(attachment, 'FRONT').image.diskfile) == png
      raise 'Private CAD figure is public' if first.image.visible?(User.anonymous)
      conflict = false
      begin
        store.save(attachment, 'front', user: actor, revision: first.revision + 1, state: state, image: png)
      rescue RedmineCadPreview::Views::Conflict
        conflict = true
      end
      raise 'CAD optimistic locking is not enforced' unless conflict
      raise 'CAD named views are not independent' unless detail.reload.state == state
      store.delete(attachment, 'front', revision: first.revision)
      raise 'Deleting one view removed another' unless store.find(attachment, 'detail').id == detail.id
      raise ActiveRecord::Rollback
    end
  end
ensure
  Attachment.storage_path = previous_storage
  User.current = previous_user
end
puts 'CAD deployment check: PASS (real DWG conversion, assets, macro, figure validation, independent views, revision conflict)'
