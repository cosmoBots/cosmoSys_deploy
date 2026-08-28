require 'digest'
require 'yaml'

package_path = ARGV.fetch(0)
package = YAML.safe_load_file(package_path, permitted_classes: [], aliases: false)
metadata = package.fetch('package')
registry_setting = 'cosmosys_managed_content_registry'

Setting.define_setting(registry_setting, 'default' => {}, 'serialized' => true) \
  unless Setting.available_settings.key?(registry_setting)
registry = Setting[registry_setting]
registry = {} unless registry.is_a?(Hash)
registry = registry.deep_dup

author = User.active.where(admin: true).order(:id).first || User.anonymous

def ensure_project(definition)
  project = Project.find_by(identifier: definition.fetch('identifier')) || Project.new
  if project.persisted? && project.name != definition.fetch('name')
    warn "Keeping administrator project name #{project.name.inspect} for #{project.identifier}"
  else
    project.name = definition.fetch('name')
  end
  project.identifier = definition.fetch('identifier') if project.new_record?
  project.cscode = definition.fetch('cscode') if project.new_record?
  project.is_public = definition.fetch('public')
  project.enabled_module_names = (project.enabled_module_names + ['wiki']).uniq
  project.save!
  project
end

def write_page(wiki:, title:, text:, author:, comments:, overwrite:)
  page = wiki.find_or_new_page(title)
  return page if page.persisted? && !overwrite

  if page.new_record?
    page.content = WikiContent.new(page: page, text: text, author: author, comments: comments)
    page.save!
  else
    page.content.update!(text: text, author: author, comments: comments)
  end
  page
end

package.fetch('projects').each do |project_definition|
  project = ensure_project(project_definition)
  wiki = project.wiki || Wiki.create!(project: project, start_page: project_definition.fetch('start_page'))

  project_definition.fetch('pages').each do |page_definition|
    registry_key = [metadata.fetch('key'), project_definition.fetch('key'), page_definition.fetch('key')].join(':')
    body = page_definition.fetch('body').strip + "\n"
    source_hash = Digest::SHA256.hexdigest(body)
    previous = registry[registry_key]
    existing = wiki.find_page(page_definition.fetch('internal_title'), with_redirect: false)
    existing_hash = Digest::SHA256.hexdigest(existing.content.text) if existing&.content

    if previous.is_a?(Hash) && existing_hash && existing_hash != previous['source_hash']
      warn "Managed page #{registry_key} was modified locally; replacing it with package content"
    end

    internal_page = write_page(
      wiki: wiki,
      title: page_definition.fetch('internal_title'),
      text: body,
      author: author,
      comments: "Managed content #{metadata.fetch('key')} v#{metadata.fetch('version')}",
      overwrite: existing_hash != source_hash
    )

    facade_text = "{{include(#{page_definition.fetch('internal_title')})}}\n"
    facade_page = write_page(
      wiki: wiki,
      title: page_definition.fetch('facade_title'),
      text: facade_text,
      author: author,
      comments: 'Administrator-owned help facade',
      overwrite: false
    )

    registry[registry_key] = {
      'package_version' => metadata.fetch('version'),
      'project_id' => project.id,
      'wiki_page_id' => internal_page.id,
      'facade_page_id' => facade_page.id,
      'source_hash' => source_hash,
      'visibility' => project.is_public? ? 'public' : 'private',
      'locale' => metadata.fetch('locale'),
      'formatter' => metadata.fetch('formatter')
    }
  end
end

Setting[registry_setting] = registry
puts "Applied #{metadata.fetch('key')} content package v#{metadata.fetch('version')}"
