require 'json'

# Invoked over the existing SSH connection, not a public HTTP route.
class TextBridge
  class Conflict < StandardError; end
  def initialize(project_id, user: nil)
    @user = user || User.find_by!(login: ENV.fetch('COSMOSYS_EXCHANGE_USER', 'editor'))
    raise 'Inactive account' unless @user.active?
    User.current = @user
    @project = Project.find_by!(identifier: project_id)
    raise 'Project inaccessible' unless @project.visible?(@user)
  end

  def issue_fields(issue)
    fields = {'subject' => issue.subject.to_s, 'description' => issue.description.to_s.gsub(/\r\n?/, "\n")}
    %w[cs_reaction cs_roll_expression cs_roll_result].each do |field|
      value = issue.public_send(field) if issue.respond_to?(field)
      fields[field] = value.to_s unless value.nil? || value.to_s.empty?
    end
    fields
  end

  def snapshot
    records = []
    if @user.allowed_to?(:view_issues, @project)
      scope = Issue.visible(@user).where(project_id: @project.id)
      scope = scope.reorder(Arel.sql(Cosmosys::ChapterSort.sql.join(', ')))
      scope.each do |issue|
        fields = issue_fields(issue)
        editable = %w[subject description].select { |f|
          @user.allowed_to?(:edit_issues, @project) && issue.safe_attribute?(f, @user)
        }
        records << {'key' => "issue:#{issue.id}", 'label' => "Ficha #{issue.csid.presence || issue.id}",
                    'parent' => issue.parent_id ? "issue:#{issue.parent_id}" : nil,
                    'position' => issue.csposition,
                    'revision' => issue.lock_version, 'fields' => fields, 'editable' => editable}
      end
    end
    if @project.wiki && @user.allowed_to?(:view_wiki_pages, @project)
      @project.wiki.pages.includes(:content).sort_by { |p| [p.title.downcase, p.id] }.each do |page|
        next unless page.content
        records << {'key' => "wiki:#{page.id}", 'label' => "Página #{page.title}",
                    'parent' => page.parent_id ? "wiki:#{page.parent_id}" : nil,
                    'revision' => page.content.version, 'fields' => {'text' => page.content.text.to_s},
                    'editable' => (@user.allowed_to?(:edit_wiki_pages, @project) && page.editable_by?(@user)) ? ['text'] : []}
      end
    end
    {'project' => {'identifier' => @project.identifier, 'name' => @project.name, 'id' => @project.id},
     'records' => records}
  end

  def apply(changes, dry_run: false)
    raise 'Invalid changes' unless changes.is_a?(Array) && changes.length.between?(1, 5000)
    keys = changes.map { |c| c.fetch('key') }
    raise 'Repeated identity' unless keys.uniq.length == keys.length
    changed = []
    ActiveRecord::Base.transaction(requires_new: true) do
      @project.lock!
      pending = []
      creations = []
      changes.sort_by { |c| c.fetch('key') }.each do |change|
        kind, id = change.fetch('key').split(':', 2)
        if kind == 'new'
          raise 'Invalid new identity' unless id.match?(/\A[0-9a-f]{64}\z/)
          raise 'Creation denied' unless @user.allowed_to?(:add_issues, @project)
          after=change.fetch('after')
          raise 'Invalid new fields' unless after.is_a?(Hash) && after.keys.sort==%w[description subject] && after.values.all?{|v|v.is_a?(String) && v.bytesize<=5_000_000}
          marker="Intercambio Word: apartado nuevo #{id}"
          existing=Issue.visible(@user).where(project_id:@project.id).joins(:journals).where(journals:{notes:marker}).first
          if existing
            raise Conflict, 'El apartado ya se creó y luego cambió. Vuelve a exportar.' unless after.all?{|f,v|existing.public_send(f).to_s.gsub(/\r\n?/,"\n")==v}
            next
          end
          creation=change.fetch('create')
          raise 'Invalid source identity' unless %w[parent source].all?{|k|creation[k].is_a?(String) && creation[k].match?(/\Aissue:[1-9]\d*\z/)}
          parent=Issue.visible(@user).where(project_id:@project.id).lock.find(creation['parent'].split(':').last)
          source=Issue.visible(@user).where(project_id:@project.id).lock.find(creation['source'].split(':').last)
          raise Conflict, 'El árbol original cambió. Vuelve a exportar.' unless source.parent_id==parent.id && !source.children.exists?
          item=Issue.new(project:@project,tracker:source.tracker,author:@user,parent_issue_id:parent.id,
                         subject:after['subject'],description:after['description'])
          raise 'Creation fields denied' unless %w[subject description parent_issue_id].all?{|f|item.safe_attribute?(f,@user)}
          creations << [item,marker]
          changed << change['key']
          next
        end
        raise 'Invalid identity' unless %w[issue wiki].include?(kind) && id.match?(/\A[1-9]\d*\z/)
        before = change.fetch('before')
        after = change.fetch('after')
        raise 'Invalid fields' unless before.is_a?(Hash) && after.is_a?(Hash) &&
                                      before.keys.sort == after.keys.sort && !after.empty?
        raise 'Invalid text' unless (before.values + after.values).all? { |v| v.is_a?(String) && v.bytesize <= 5_000_000 }
        if kind == 'issue'
          item = Issue.visible(@user).where(project_id: @project.id).lock.find(id)
          raise 'Editing denied' unless @user.allowed_to?(:edit_issues, @project) &&
            after.keys.all? { |f| %w[subject description].include?(f) && item.safe_attribute?(f, @user) }
          current = after.keys.to_h { |f| [f, item.public_send(f).to_s.gsub(/\r\n?/, "\n")] }
          revision = item.lock_version
        else
          raise 'Wiki unavailable' unless @project.wiki
          page = @project.wiki.pages.lock.find(id)
          raise 'Editing denied' unless @user.allowed_to?(:edit_wiki_pages, @project) &&
            page.editable_by?(@user) && after.keys == ['text']
          item = WikiContent.lock.find_by!(page_id: page.id)
          current = {'text' => item.text.to_s.gsub(/\r\n?/, "\n")}
          revision = item.version
        end
        next if current == after
        raise Conflict, "El original cambió: #{change['key']}" unless current == before &&
          revision == change.fetch('revision')
        pending << [kind, item, after]
        changed << change['key']
      end
      pending.each do |kind, item, after|
        if kind == 'issue'
          item.init_journal(@user, 'Texto revisado mediante intercambio Word/TXT')
          item.safe_attributes = after
          raise 'Some fields are not writable' unless after.all? { |f, v| item.public_send(f).to_s.gsub(/\r\n?/, "\n") == v }
        else
          item.assign_attributes(text: after.fetch('text'), author: @user,
                                 comments: 'Texto revisado mediante intercambio Word/TXT')
        end
        item.save!
        item.reload
        raise 'El servidor transformó el texto; se ha revertido el lote' unless after.all? { |f, v|
          item.public_send(f).to_s.gsub(/\r\n?/, "\n") == v
        }
      end
      creations.each do |item,marker|
        position=Issue.where(parent_id:item.parent_id).maximum(:csposition).to_i+1
        item.csposition=position
        expected_text={'subject'=>item.subject.to_s.gsub(/\r\n?/,"\n"),'description'=>item.description.to_s.gsub(/\r\n?/,"\n")}
        item.save!
        item.update_columns(csposition:position) unless item.csposition==position
        item.reload
        raise 'El servidor transformó el apartado; se ha revertido el lote' unless expected_text.all?{|f,v|item.public_send(f).to_s.gsub(/\r\n?/,"\n")==v}
        item.journals.create!(user:@user,notes:marker)
      end
      raise ActiveRecord::Rollback if dry_run
    end
    {'changed' => changed, 'dry_run' => dry_run}
  end
end

unless defined?(TEXT_BRIDGE_LIBRARY)
  begin
    input = JSON.parse(STDIN.read(25_000_001))
    bridge = TextBridge.new(input.fetch('project'))
    result = case input.fetch('operation')
             when 'export'
               ActiveRecord::Base.transaction(isolation: :repeatable_read) { bridge.snapshot }
             when 'check' then bridge.apply(input.fetch('changes'), dry_run: true)
             when 'apply' then bridge.apply(input.fetch('changes'))
             else raise 'Unknown operation'
             end
    puts JSON.generate({'ok' => true, 'result' => result})
  rescue StandardError => e
    puts JSON.generate({'ok' => false, 'error' => e.message, 'type' => e.class.name})
    exit 1
  end
end
