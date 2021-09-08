# frozen_string_literal: true

require_relative 'lib/distributed-lock-google-cloud-storage/version'

Gem::Specification.new do |s|
  s.name        = 'distributed-lock-google-cloud-storage'
  s.version     = DistributedLock::GoogleCloudStorage::Version::VERSION_STRING
  s.summary     = "Distributed lock based on Google Cloud Storage"
  s.description = "A distributed lock based on Google Cloud Storage"
  s.authors     = ["Hongli Lai"]
  s.email       = 'honglilai@gmail.com'
  s.files       = Dir["lib/**/*.rb", "defs/*.rbi"]
  s.homepage    = 'https://github.com/FooBarWidget/distributed-lock-google-cloud-storage-ruby'
  s.license     = 'MIT'
  s.required_ruby_version = '>= 2.7'
  s.add_runtime_dependency 'google-cloud-storage', '~> 1.32'
end
