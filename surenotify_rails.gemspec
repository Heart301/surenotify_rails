require_relative "lib/surenotify_rails/version"

Gem::Specification.new do |s|
  s.name        = "surenotify_rails"
  s.version     = SurenotifyRails::VERSION
  s.authors     = ["Leo Chen"]
  s.email       = ["pominx@gmail.com"]
  s.homepage    = "https://github.com/pominx/surenotify_rails"
  s.summary     = "Rails Action Mailer adapter for Surenotify (NewsLeopard)"
  s.description = "An adapter for using Surenotify with Rails and Action Mailer"
  s.license     = "MIT"

  s.metadata = {
    "homepage_uri"          => s.homepage,
    "source_code_uri"       => s.homepage,
    "rubygems_mfa_required" => "true"
  }

  s.required_ruby_version = ">= 3.0"

  s.files = Dir["lib/**/*", "MIT-LICENSE", "README.md"]

  s.add_dependency "actionmailer", ">= 6.0"

  s.add_development_dependency "rake"
  s.add_development_dependency "rspec", "~> 3.13"
  s.add_development_dependency "webmock", "~> 3.0"
end
