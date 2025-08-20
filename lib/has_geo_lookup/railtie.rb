# frozen_string_literal: true

require 'rails/railtie'

module HasGeoLookup
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/has_geo_lookup.rake', __dir__)
    end
  end
end