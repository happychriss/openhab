# -*- encoding: utf-8 -*-
# stub: openhab-scripting 5.39.0 ruby lib

Gem::Specification.new do |s|
  s.name = "openhab-scripting".freeze
  s.version = "5.39.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "changelog_uri" => "https://openhab.github.io/openhab-jruby/file.CHANGELOG.html", "documentation_uri" => "https://openhab.github.io/openhab-jruby/", "homepage_uri" => "https://openhab.github.io/openhab-jruby/", "rubygems_mfa_required" => "true", "source_code_uri" => "https://github.com/openhab/openhab-jruby" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Brian O'Connell".freeze, "Cody Cutrer".freeze, "Jimmy Tanagra".freeze]
  s.date = "1980-01-02"
  s.email = ["broconne+github@gmail.com".freeze, "cody@cutrer.us".freeze, "jcode@tanagra.id.au".freeze]
  s.homepage = "https://openhab.github.io/openhab-jruby/".freeze
  s.licenses = ["EPL-2.0".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 3.1.4".freeze)
  s.rubygems_version = "3.3.26".freeze
  s.summary = "JRuby Helper Libraries for openHAB Scripting".freeze

  s.installed_by_version = "3.3.26" if s.respond_to? :installed_by_version

  if s.respond_to? :specification_version then
    s.specification_version = 4
  end

  if s.respond_to? :add_runtime_dependency then
    s.add_runtime_dependency(%q<bundler>.freeze, ["~> 2.2"])
    s.add_runtime_dependency(%q<marcel>.freeze, ["~> 1.0"])
    s.add_runtime_dependency(%q<method_source>.freeze, ["~> 1.0"])
  else
    s.add_dependency(%q<bundler>.freeze, ["~> 2.2"])
    s.add_dependency(%q<marcel>.freeze, ["~> 1.0"])
    s.add_dependency(%q<method_source>.freeze, ["~> 1.0"])
  end
end
