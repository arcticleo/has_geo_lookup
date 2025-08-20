# frozen_string_literal: true

require_relative "lib/has_geo_lookup/version"

Gem::Specification.new do |spec|
  spec.name = "has_geo_lookup"
  spec.version = HasGeoLookup::VERSION
  spec.authors = ["Michael Edlund"]
  spec.email = ["medlund@mac.com"]

  spec.summary = "Geographic lookup functionality using GeoBoundaries and Geonames data"
  spec.description = "A Ruby gem that provides geographic lookup functionality using both GeoBoundaries.org and Geonames.org datasets. Features include coordinate validation with radian/degree detection, spatial containment queries, distance-based lookups, and data coverage analysis utilities."
  spec.homepage = "https://github.com/arcticleo/has_geo_lookup" 
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/arcticleo/has_geo_lookup"
  spec.metadata["changelog_uri"] = "https://github.com/arcticleo/has_geo_lookup/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Core dependencies
  spec.add_dependency "rails", ">= 7.0.0"
  spec.add_dependency "activesupport", ">= 7.0.0"
  spec.add_dependency "activerecord", ">= 7.0.0"
  
  # Geographic data dependencies  
  spec.add_dependency "iso_3166", ">= 0.1.0"
  spec.add_dependency "rgeo", "~> 3.0"
  spec.add_dependency "rgeo-geojson", "~> 2.0"
  
  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
