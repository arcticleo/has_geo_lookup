# HasGeoLookup

Rails gem for geographic lookup functionality using GeoBoundaries.org and Geonames.org datasets. Provides coordinate validation with automatic radian/degree detection, spatial containment queries, distance-based lookups, and metropolitan area support.

## Features

- **Coordinate Validation** - Automatically detect and convert between radians and degrees using country boundary validation
- **Spatial Queries** - PostGIS-optimized boundary containment with graceful fallback for other databases
- **Distance-Based Lookup** - Find nearest geographic features within specified radius
- **Administrative Boundaries** - Query points against ADM1-ADM4 level boundaries from GeoBoundaries.org
- **Metro Area Support** - Define custom metropolitan areas as collections of administrative boundaries
- **Multi-Source Comparison** - Compare geographic data across different sources with extensible hooks
- **Data Coverage Analysis** - Utilities for analyzing geographic data completeness

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'has_geo_lookup'
```

And then execute:

```bash
bundle install
```

## Setup

### 1. Generate Database Migrations

```bash
rails generate has_geo_lookup:install
```

This creates migrations for all required tables:
- `geonames` - Geographic place data from Geonames.org
- `geoboundaries` - Administrative boundaries from GeoBoundaries.org
- `feature_codes` - Classification codes for geographic features
- `metros` - Metropolitan area definitions
- `metros_geoboundaries` - Join table for metro-boundary associations

### 2. Run Migrations

```bash
rails db:migrate
```

### 3. Import Geographic Data

Import geoboundaries and geonames for specific countries:

```bash
# Import both datasets for United States (recommended)
rails geo:import[US]

# Import for multiple countries
rails geo:import[CA]  # Canada
rails geo:import[GB]  # United Kingdom

# Or import datasets separately
rails geoboundaries:import[US]  # Administrative boundaries only
rails geonames:import[US]       # Geographic place names only
```

### 4. Include in Your Models

Add the concern to any model with `latitude` and `longitude` attributes:

```ruby
class Listing < ApplicationRecord
  include HasGeoLookup
  
  # Your model must have these attributes:
  # - latitude (decimal)
  # - longitude (decimal)
end
```

## Database Requirements

### MySQL 8.0+ with Spatial Extensions (Recommended)

The gem works well with MySQL 8.0+ spatial support:

```ruby
# Gemfile
gem 'mysql2'
```

MySQL 8.0+ provides:
- GEOMETRY column type for storing boundary polygons
- ST_Contains, ST_GeomFromText, and other spatial functions
- Coordinate validation using actual country boundaries
- Spatial indexing for performance

### PostgreSQL with PostGIS (Also Supported)

For PostgreSQL databases with PostGIS:

```ruby
# Gemfile
gem 'activerecord-postgis-adapter'
```

PostGIS provides enhanced spatial capabilities and may offer better performance for complex spatial operations.

### Other Databases

For SQLite and databases without spatial extensions:
- Spatial queries will be limited but functional
- Coordinate validation uses fallback detection methods
- Basic geographic lookup functionality remains available

## Usage

### Basic Geographic Lookup

```ruby
listing = Listing.find(123)

# Find nearest populated places within 50km
places = listing.nearest_geonames(
  feature_code: "PPL",    # Populated place
  radius_km: 50,
  limit: 10
)

# Find containing administrative boundaries
boundaries = listing.containing_geoboundaries(level: "ADM2") # Counties

# Get geographic summary
summary = listing.compare_geo_sources
puts summary
```

### Coordinate Validation

The gem automatically handles coordinate format detection:

```ruby
# These coordinates could be in radians or degrees
lat, lng = 0.768131687, 0.077125907  # Uzès, France in radians

# Automatically detects format and converts to degrees
validated_lat, validated_lng = listing.validate_and_convert_coordinates(lat, lng, "FR")
# => [44.011, 4.419] (converted to degrees)

# Already in degrees - no conversion needed
validated_lat, validated_lng = listing.validate_and_convert_coordinates(44.011, 4.419, "FR")
# => [44.011, 4.419] (unchanged)
```

### Metro Area Support

Define custom metropolitan areas:

```ruby
# Create a metro area
bay_area = Metro.create!(
  name: "San Francisco Bay Area",
  country_code: "US",
  population: 7_750_000
)

# Associate with counties (geoboundaries)
sf_county = Geoboundary.find_by(name: "San Francisco County")
alameda_county = Geoboundary.find_by(name: "Alameda County")
bay_area.geoboundaries << [sf_county, alameda_county]

# Check if coordinates are in metro area
bay_area.contains_point?(37.7749, -122.4194) # => true

# Get metro area statistics
bay_area.total_area_km2      # => 18040.5
bay_area.population_density   # => 429.8
bay_area.boundary_names      # => ["San Francisco County", "Alameda County", ...]
```

### Data Coverage Analysis

```ruby
# Analyze data completeness
coverage = HasGeoLookup::DataCoverage.coverage_status("US")
puts coverage[:geonames_count]      # Number of geonames records
puts coverage[:boundaries_count]    # Number of boundary records
puts coverage[:feature_coverage]    # Coverage by feature type

# Check if specific data exists
HasGeoLookup::DataCoverage.has_boundary_data?("US", "ADM2")  # => true
HasGeoLookup::DataCoverage.has_geonames_data?("US")          # => true
```

### Advanced Usage

#### Custom Source Comparison

Extend geographic comparison for your specific data sources:

```ruby
class Listing < ApplicationRecord
  include HasGeoLookup
  
  # Define additional data sources for comparison
  def additional_source_columns
    ['api_latitude', 'api_longitude', 'geocoded_lat', 'geocoded_lng']
  end
  
  def additional_source_legend
    {
      'API' => 'Third-party API data',
      'Geocoded' => 'Address-based geocoding'
    }
  end
  
  def get_source_value(column_name)
    case column_name
    when 'api_latitude', 'api_longitude'
      # Custom logic to fetch from your API
    when 'geocoded_lat', 'geocoded_lng'  
      # Custom logic for geocoded coordinates
    end
  end
end
```

#### Distance Calculations

```ruby
# Find records within radius using database query
nearby_listings = Listing.joins(:nearest_geonames)
                         .where("geonames.feature_code = 'PPL'")
                         .where(geonames: { country_code: "US" })

# Calculate distance between two points
distance_km = listing.distance_to_point(40.7128, -74.0060)
```

## Configuration

### Rails Generators

Customize migration generation:

```ruby
# config/application.rb
config.generators do |g|
  g.has_geo_lookup_skip_migrations = false  # Set to true to skip auto-generation
end
```

### PostGIS Configuration

For PostGIS databases, ensure the extension is enabled:

```ruby
# In a migration or database setup
enable_extension 'postgis'
```

## Data Sources

This gem integrates data from:

- **[GeoBoundaries.org](https://www.geoboundaries.org/)** - Administrative boundary polygons (ADM1-ADM4 levels)
- **[Geonames.org](http://www.geonames.org/)** - Geographic place names and coordinates
- **[ISO 3166](https://en.wikipedia.org/wiki/ISO_3166)** - Country code validation

## Performance Considerations

### Index Analysis and Optimization

The gem includes built-in tools to analyze and optimize database indexes for HasGeoLookup functionality:

```bash
# Check index coverage for all models using HasGeoLookup
rake has_geo_lookup:check_indexes

# Preview what indexes would be created (dry run)
rake has_geo_lookup:preview_indexes

# Generate Rails migration for missing columns and indexes  
rake has_geo_lookup:create_indexes

# Analyze a specific model in detail
rake has_geo_lookup:analyze_model[Listing]
```

**Programmatic Index Management:**

```ruby
# Get performance analysis for all models
results = HasGeoLookup::IndexChecker.analyze_all_models

# Check a specific model
analysis = HasGeoLookup::IndexChecker.check_model(Listing)
puts "Missing indexes: #{analysis[:missing_indexes]}"
puts "Recommendations: #{analysis[:recommendations]}"

# Generate migration file for missing columns and indexes
migration_path = HasGeoLookup::IndexChecker.generate_index_migration
# Or for a specific model:
migration_path = HasGeoLookup::IndexChecker.generate_index_migration(Listing)

# Generate a comprehensive performance report
puts HasGeoLookup::IndexChecker.performance_report
```

**Setup and Index Creation:**

The `create_indexes` task generates proper Rails migration files that can be committed to version control and run as part of your deployment process. The migration includes:

- **Required columns**: Adds `latitude` and `longitude` decimal columns if missing
- **Recommended indexes**: Creates optimized database indexes for geographic queries
- **Proper rollback**: Includes reversible `down` migration methods

This ensures all environments get the same database structure and maintains proper migration history.

### Database Optimization

For large datasets:

```ruby
# Coordinate indexes (essential for spatial queries)
add_index :your_table, [:latitude, :longitude]
add_index :your_table, :latitude
add_index :your_table, :longitude

# Geographic attribute indexes (for filtering and joining)
add_index :your_table, :country
add_index :your_table, :state_or_province  
add_index :your_table, :city
add_index :your_table, :postal_code

# For geoboundaries and geonames tables
add_index :geonames, [:country_code, :feature_code]
add_index :geoboundaries, [:level, :shape_iso]

# For PostGIS, spatial indexes are created automatically
```

### Query Optimization

```ruby
# Use specific feature codes to limit results
places = listing.nearest_geonames(
  feature_code: ["PPL", "PPLA", "PPLA2"],  # Cities and towns only
  limit: 5
)

# Specify administrative levels for boundaries
boundaries = listing.containing_geoboundaries(level: ["ADM1", "ADM2"])
```

## Development

### Running Tests

```bash
cd has_geo_lookup
bundle install
ruby -Ilib -Itest test/has_geo_lookup_test.rb
```

### Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Add tests for your changes
4. Ensure tests pass
5. Commit your changes (`git commit -am 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Create a Pull Request

## License

This gem is available as open source under the terms of the MIT License.

## Changelog

### Version 0.1.0
- Initial release
- Coordinate validation with radian/degree detection
- PostGIS spatial queries with fallback support
- GeoBoundaries and Geonames integration
- Metro area support
- Comprehensive test suite
- Rails generators for easy setup
