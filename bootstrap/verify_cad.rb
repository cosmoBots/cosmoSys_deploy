# frozen_string_literal: true

# Shared, non-persistent check for disposable validation and instance updates.
require 'base64'
require 'net/http'
require 'open3'
require 'ostruct'
require 'tmpdir'

abort('CAD viewer is not loaded') unless defined?(RedmineCadPreview)
abort('CAD integration is not loaded') unless defined?(CosmosysCadPreview::ReportView)
abort('ImageMagick is unavailable for CAD figures') unless File.executable?('/usr/bin/magick')
abort('DWG converter is unavailable') unless RedmineCadPreview::DwgConverter.available?

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
  'cosmosys_cad_preview/report_view.js' => %w[captureReportImage],
  'cosmosys_cad_preview/report_capture.js' => %w[alphaBounds captureReportImage]
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
begin
  Dir.mktmpdir('cad-deploy-check-') do |directory|
    Attachment.storage_path = directory
    attachment = OpenStruct.new(id: 1, digest: 'cad-check', filesize: 1)
    actor = OpenStruct.new(id: 0)
    state = { 'version' => 1, 'projection' => 'drawing', 'center' => [0, 0],
              'view_width' => 100, 'aspect' => 1.5 }
    png, error, result = Open3.capture3('/usr/bin/magick', '-size', '2x1', 'xc:#808080', 'png:-', binmode: true)
    abort("CAD figure generation failed: #{error}") unless result.success?
    payload = { 'state' => state, 'cad_report_image' => "data:image/png;base64,#{Base64.strict_encode64(png)}", 'revision' => nil }
    store = CosmosysCadPreview::ReportView
    first = store.save!(attachment, payload, actor, view: 'front')
    store.save!(attachment, payload, actor, view: 'detail')
    abort('CAD named views share revisions') if store.read(attachment, view: 'detail')['revision'] == first['revision']
    abort('CAD default view was overwritten') if store.read(attachment)
    abort('CAD figure changed') unless store.read(attachment, view: 'front')['png'] == Base64.strict_encode64(png)
    begin
      store.save!(attachment, payload, actor, view: 'front')
      abort('CAD optimistic locking is not enforced')
    rescue CosmosysCadPreview::ReportView::Conflict
      # Expected: an old revision must never overwrite a saved view.
    end
  end
ensure
  Attachment.storage_path = previous_storage
end
puts 'CAD deployment check: PASS (real DWG conversion, assets, macro, figure validation, independent views, revision conflict)'
