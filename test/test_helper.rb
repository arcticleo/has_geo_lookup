# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "has_geo_lookup"

require "minitest/autorun"
require "active_support"
require "active_record"

# Set up a minimal Rails-like environment for testing
ActiveSupport::TestCase.test_order = :random

# Only set up test database when actually running gem tests from the gem directory
# Check if we're running tests from within the gem itself
gem_test_mode = Dir.pwd.end_with?('has_geo_lookup') || ENV['GEM_TEST_MODE'] == 'true'

if defined?(Minitest) && gem_test_mode
  # Configure database for testing (in-memory SQLite)
  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: ':memory:'
  )

  # Create tables for testing
  ActiveRecord::Schema.define do
    create_table :test_models do |t|
      t.string :name
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.timestamps
    end
    
    create_table :geonames, force: true do |t|
      t.integer :geonameid, null: false
      t.string :name, limit: 200
      t.string :country_code, limit: 2
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.string :feature_class, limit: 1
      t.string :feature_code, limit: 10
      t.integer :population
      t.decimal :elevation
      t.string :admin1_code, limit: 20
      t.string :admin2_code, limit: 80
      t.string :admin3_code, limit: 20
      t.string :admin4_code, limit: 20
      t.string :admin1_name
      t.string :admin2_name
      t.timestamps
    end
    
    create_table :geoboundaries, force: true do |t|
      t.string :name
      t.string :level
      t.string :shape_iso
      t.string :shape_group
      t.text :boundary # Placeholder for geometry in real PostGIS
      t.timestamps
    end
    
    create_table :feature_codes, force: true do |t|
      t.string :feature_class, limit: 1
      t.string :feature_code, limit: 10
      t.string :name
      t.text :description
      t.timestamps
    end
    
    create_table :metros, force: true do |t|
      t.string :name
      t.text :details
      t.string :country_code, limit: 2
      t.integer :population
      t.timestamps
    end
    
    create_join_table :metros, :geoboundaries
  end
end
