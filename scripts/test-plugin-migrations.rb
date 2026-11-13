# frozen_string_literal: true

require 'rake'

# Test the runner's ordering/failure contract without a database or Rails boot.
module Rails
  def self.application = self
  def self.load_tasks
    Rake::Task.define_task('db:schema:dump') { EVENTS << :dump }
  end
end
module Redmine
  module Plugin
    def self.all = @plugins
    def self.installed?(id) = all.any? { |plugin| plugin.id == id }
    def self.find(id) = all.find { |plugin| plugin.id == id }
    def self.plugins=(plugins)
      @plugins = plugins
    end
  end
end
EVENTS = []
FakePlugin = Struct.new(:id, :fails) do
  def migrate
    EVENTS << id
    raise 'migration failed' if fails
  end
end
class PluginMigrationsTest
  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end
  def assert_raises(exception)
    begin
      yield
    rescue exception
      return
    end
    raise "Expected #{exception}"
  end
  def setup
    EVENTS.clear
    Rake::Task.clear
  end
  def run_runner
    load File.expand_path('../bootstrap/migrate_plugins.rb', __dir__)
  end
  def test_dependencies_before_other_plugins_and_dump_last
    Redmine::Plugin.plugins = %i[cosmosys_arch cosmosys_req cosmosys cosmosys_poris].map { |id| FakePlugin.new(id) }
    run_runner
    assert_equal %i[cosmosys cosmosys_req cosmosys_arch cosmosys_poris dump], EVENTS
  end
  def test_base_variant_without_requirements
    Redmine::Plugin.plugins = [FakePlugin.new(:cosmosys)]
    run_runner
    assert_equal %i[cosmosys dump], EVENTS
  end
  def test_failure_does_not_dump_or_continue
    Redmine::Plugin.plugins = [FakePlugin.new(:cosmosys, true), FakePlugin.new(:cosmosys_req)]
    assert_raises(RuntimeError) { run_runner }
    assert_equal [:cosmosys], EVENTS
  end
end
test = PluginMigrationsTest.new
test.public_methods.grep(/^test_/).sort.each do |name|
  test.setup
  test.public_send(name)
end
puts 'Plugin migration runner: PASS (dependency order, base variant, dump last, failure stops)'
