# frozen_string_literal: true

# Redmine persists plugin settings with their string keys. Redmine-Kroki 0.5.0
# reads those settings using symbol keys in its macro. This deployment-only
# initializer is loaded after redmine_kroki and leaves the upstream plugin
# untouched.

module RedmineKrokiSettingsCompatibility
  module SettingPatch
    def plugin_redmine_kroki
      value = super
      value.is_a?(Hash) ? value.with_indifferent_access : value
    end
  end
end

setting_singleton = Setting.singleton_class
unless setting_singleton.ancestors.include?(RedmineKrokiSettingsCompatibility::SettingPatch)
  setting_singleton.prepend(RedmineKrokiSettingsCompatibility::SettingPatch)
end
