# frozen_string_literal: true

require "active_support"
require "active_support/concern"
require "active_record"

require_relative "has_geo_lookup/version"
require_relative "has_geo_lookup/concern"

# Require models
require_relative "has_geo_lookup/models/geoname"
require_relative "has_geo_lookup/models/geoboundary"
require_relative "has_geo_lookup/models/feature_code"
require_relative "has_geo_lookup/models/metro"

# Require utilities
require_relative "has_geo_lookup/index_checker"

# Require generators and railtie if Rails is available
if defined?(Rails)
  require_relative "generators/has_geo_lookup/install_generator"
  require_relative "has_geo_lookup/railtie"
end


module HasGeoLookup
  class Error < StandardError; end
end
