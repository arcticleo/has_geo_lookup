# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'

module HasGeoLookup
  module Generators
    # Generates database migrations for HasGeoLookup gem
    #
    # Creates all necessary tables for geographic lookup functionality:
    # - geonames: Geographic place data from Geonames.org
    # - geoboundaries: Administrative boundaries from GeoBoundaries.org
    # - feature_codes: Classification codes for geographic features
    # - metros: Metropolitan area definitions
    # - geoboundaries_metros: Join table for metro-boundary associations
    # - geonames_metros: Join table for geoname-metro associations
    #
    # @example Generate migrations
    #   rails generate has_geo_lookup:install
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Generate HasGeoLookup database migrations'

      # Provide a migration timestamp
      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      def create_migrations
        migration_template 'create_geonames.rb.erb', 'db/migrate/create_geonames.rb'
        sleep 1 # Ensure different timestamps
        migration_template 'create_geoboundaries.rb.erb', 'db/migrate/create_geoboundaries.rb'
        sleep 1
        migration_template 'create_feature_codes.rb.erb', 'db/migrate/create_feature_codes.rb'
        sleep 1
        migration_template 'create_metros.rb.erb', 'db/migrate/create_metros.rb'
        sleep 1
        migration_template 'create_geoboundaries_metros.rb.erb', 'db/migrate/create_geoboundaries_metros.rb'
        sleep 1
        migration_template 'create_geonames_metros.rb.erb', 'db/migrate/create_geonames_metros.rb'
      end

      def display_readme
        readme "INSTALL.md"
      end

      private

      def migration_version
        if Rails.version.start_with?('8')
          '[8.0]'
        elsif Rails.version.start_with?('7')
          '[7.0]'
        elsif Rails.version.start_with?('6')
          '[6.0]'
        else
          '[5.0]'
        end
      end
    end
  end
end