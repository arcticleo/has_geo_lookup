# frozen_string_literal: true

# app/models/concerns/has_geo_lookup.rb
#
# Comprehensive geographic lookup functionality using GeoBoundaries.org and Geonames.org data
#
# This concern provides both distance-based lookups (using Geonames.org) and precise
# geometric containment queries (using GeoBoundaries.org) for models with latitude/longitude
# coordinates. It includes data coverage utilities, municipal name cleaning, and comparison
# tools for geographic data quality analysis.
#
# @example Basic usage
#   class Listing < ApplicationRecord
#     include HasGeoLookup
#   end
#   
#   listing = Listing.first
#   listing.nearest_geonames(feature_class: "P", limit: 3)
#   listing.containing_boundaries
#   listing.compare_geo_sources
#
# @see HasGeoLookup::DataCoverage For geographic data coverage analysis utilities
module HasGeoLookup
  extend ActiveSupport::Concern

  class_methods do
    # Efficiently select a random record that has coordinate data
    #
    # This method uses offset-based selection rather than ORDER BY RAND() for better
    # performance on large datasets. Only considers records with both latitude and
    # longitude values.
    #
    # @return [ActiveRecord::Base, nil] Random record with coordinates, or nil if none exist
    #
    # @example
    #   Listing.random_with_coords
    #   # => #<Listing id: 123, latitude: 40.7128, longitude: -74.0060, ...>
    def random_with_coords
      coord_scope = where.not(latitude: nil, longitude: nil)
      count = coord_scope.count
      return nil if count == 0
      coord_scope.offset(rand(count)).first
    end
  end

  # Struct to wrap a Geoname result with distance in kilometers
  Result = Struct.new(:record, :distance_km, :feature_class, :feature_code)
  
  # Struct to wrap a Geoboundary result for consistent API
  GeoboundaryResult = Struct.new(:record, :distance_km, :level, :name) do
    def feature_class; level; end
    def feature_code; level; end
  end

  # Find nearby Geonames of a given type within a specified radius
  #
  # This method performs distance-based lookup of geographic features from the Geonames.org
  # dataset. It supports filtering by feature type and uses bounding box optimization for
  # better performance on large datasets.
  #
  # @param feature_class [String, nil] Geoname feature class (e.g., "P" for populated places)
  # @param feature_code [String, nil] Geoname feature code (e.g., "PPL" for populated place)  
  # @param keyword [String, nil] Search feature names/descriptions to auto-determine criteria
  # @param radius_km [Integer] Search radius in kilometers (default: 100)
  # @param limit [Integer] Maximum results to return (default: 5)
  #
  # @return [Array<Result>] Array of Result structs with :record, :distance_km, :feature_class, :feature_code
  #
  # @example Find closest populated places
  #   listing.nearest_geonames(feature_class: "P", radius_km: 50)
  #
  # @example Find administrative divisions by keyword
  #   listing.nearest_geonames(keyword: "county", limit: 1)
  def nearest_geonames(feature_class: nil, feature_code: nil, keyword: nil, radius_km: 100, limit: 5)
    return [] unless latitude && longitude

    if keyword && (feature_class.nil? || feature_code.nil?)
      fc = find_feature_class_and_code_by_keyword(keyword)
      feature_class ||= fc&.first
      feature_code  ||= fc&.last
    end

    return [] unless feature_code || feature_class

    # Calculate rough bounding box for fast filtering before expensive distance calculations
    # 1 degree ≈ 111km, so calculate degree offset for the radius
    lat_offset = radius_km / 111.0
    lng_offset = radius_km / (111.0 * Math.cos(Math::PI * latitude / 180.0))

    query = Geoname.where.not(latitude: nil, longitude: nil)

    query = query.where(feature_code: feature_code)         if feature_code
    query = query.where(feature_class: feature_class)       if feature_class

    # Add bounding box filter first (uses indexes, very fast)
    query = query.where(
      latitude: (latitude - lat_offset)..(latitude + lat_offset),
      longitude: (longitude - lng_offset)..(longitude + lng_offset)
    )

    query = query.select(<<~SQL.squish)
      geonames.*,
      (6371 * acos(
        cos(radians(#{latitude}))
        * cos(radians(latitude))
        * cos(radians(longitude) - radians(#{longitude}))
        + sin(radians(#{latitude}))
        * sin(radians(latitude))
      )) AS distance_km
    SQL

    query = query.having("distance_km <= ?", radius_km)
                 .order("distance_km ASC")
                 .limit(limit)

    query.map do |record|
      Result.new(record, record.try(:distance_km).to_f, feature_class, feature_code)
    end
  end

  # Looks up the closest county or parish-level area using feature_code = ADM2.
  #
  # Options:
  #   :radius_km — limit search radius (default: 50)
  #   :country_code — optionally restrict by country
  #
  # Returns a Result struct with distance and matched geoname.
  def closest_county_or_parish(radius_km: 50, country_code: nil)
    nearest_geonames(
      feature_class: "A",
      feature_code: "ADM2",
      radius_km: radius_km,
      # country_code: country_code,
      limit: 1
    ).first
  end

  # Looks up the closest subdivision (e.g., neighborhood or district)
  # Defaults to feature_code = "PPLX" and 1 km radius
  #
  # Options:
  #   :radius_km — limit search radius (default: 1)
  #   :country_code — optionally restrict by country
  #
  # Returns a Result struct with distance and matched geoname.
  def closest_subdivision(radius_km: 1, country_code: nil)
    nearest_geonames(
      feature_class: "P",
      feature_code: "PPLX",
      radius_km: radius_km,
      # country_code: country_code,
      limit: 1
    ).first
  end

  # Looks up the closest township-level area using feature_code = ADM3.
  # Falls back to ADM4, then ADM5 if no ADM3 match is found.
  #
  # Options:
  #   :radius_km — limit search radius (default: 25)
  #   :country_code — optionally restrict by country
  #
  # Returns a Result struct with distance and matched geoname.
  def closest_township(radius_km: 25, country_code: nil)
    %w[ADM3 ADM4 ADM5].each do |code|
      result = nearest_geonames(
        feature_class: "A",
        feature_code: code,
        radius_km: radius_km,
        # country_code: country_code,
        limit: 1
      ).first
      return result if result
    end

    nil
  end

  # GeoBoundaries-based equivalents using precise point-in-polygon

  # Find administrative boundaries that contain this point using precise geometric containment
  #
  # This method uses PostGIS spatial operations to determine which GeoBoundaries.org
  # administrative boundaries contain the current coordinate point. It performs automatic
  # coordinate validation and swapping for common data issues.
  #
  # @param levels [Array<String>, nil] Specific ADM levels to search (e.g., ["ADM1", "ADM2"])
  #                                   If nil, searches all available levels
  #
  # @return [Array<Geoboundary>] Array of boundary records that contain this point,
  #                             ordered by administrative level
  #
  # @example Find all containing boundaries
  #   listing.containing_boundaries
  #
  # @example Find only state and county level
  #   listing.containing_boundaries(levels: ["ADM1", "ADM2"])
  def containing_boundaries(levels: nil)
    return [] unless latitude && longitude

    # Validate coordinate ranges
    lat = latitude.to_f
    lng = longitude.to_f
    
    # Check if coordinates are swapped (common data issue)
    if !lat.between?(-90, 90)
      # Try swapping if latitude is invalid but longitude could be a valid latitude
      if lng.between?(-90, 90) && lat.between?(-180, 180)
        lat, lng = lng, lat
      else
        # Invalid coordinates that can't be fixed by swapping
        return []
      end
    elsif !lng.between?(-180, 180)
      # Longitude is invalid but latitude is valid - this is unusual, reject
      return []
    end

    # MySQL spatial functions expect POINT(latitude longitude) format (different from PostGIS)
    point_wkt = "POINT(#{lat} #{lng})"
    
    query = Geoboundary.where(
      "ST_Contains(boundary, ST_GeomFromText(?, 4326))",
      point_wkt
    )
    
    
    query = query.where(level: levels) if levels
    
    # Add limit to prevent memory issues on large datasets
    query.order(:level).limit(50)
  rescue => e
    Rails.logger&.error "Spatial query failed for coordinates #{lat}, #{lng}: #{e.message}"
    []
  end

  # Returns the boundary at a specific level that contains this point
  def containing_boundary(level)
    containing_boundaries(levels: level).first
  end

  # GeoBoundary equivalent of closest_county_or_parish
  # Returns the ADM2 boundary that contains this point, with fallback to closest geoname
  def county_or_parish_boundary
    # First try exact containment
    boundary = containing_boundary('ADM2')
    return GeoboundaryResult.new(boundary, 0.0, 'ADM2', boundary.name) if boundary
    
    # Fallback to closest geoname approach
    geoname_result = closest_county_or_parish
    if geoname_result && geoname_result.record
      # Try coordinate bridge: use geoname coordinates to find GeoBoundaries match
      # This improves language consistency (e.g., "Lisbon" → "Lisboa")
      geoname_lat = geoname_result.record.latitude
      geoname_lng = geoname_result.record.longitude
      
      if geoname_lat && geoname_lng
        # Create temporary checker at geoname coordinates
        temp_checker = Object.new.extend(HasGeoLookup)
        temp_checker.define_singleton_method(:latitude) { geoname_lat }
        temp_checker.define_singleton_method(:longitude) { geoname_lng }
        
        bridge_boundary = temp_checker.containing_boundary('ADM2')
        if bridge_boundary
          return GeoboundaryResult.new(bridge_boundary, geoname_result.distance_km, 'ADM2', bridge_boundary.name)
        end
      end
      
      # If coordinate bridge fails, use original geoname result
      return geoname_result
    end
    
    nil
  end

  # GeoBoundary equivalent of closest_township  
  # Returns ADM3, ADM4 or ADM5 boundary that contains this point, with fallback
  def township_boundary
    # Try ADM3 first, then ADM4, then ADM5
    %w[ADM5 ADM4 ADM3].each do |level|
      boundary = containing_boundary(level)
      return GeoboundaryResult.new(boundary, 0.0, level, boundary.name) if boundary
    end
    
    # Fallback to closest geoname approach
    geoname_result = closest_township
    return geoname_result if geoname_result
    
    nil
  end

  # GeoBoundary equivalent for state/province
  # Returns the ADM1 boundary that contains this point
  def state_or_province_boundary
    boundary = containing_boundary('ADM1')
    return GeoboundaryResult.new(boundary, 0.0, 'ADM1', boundary.name) if boundary
    
    # No geoname fallback for ADM1 since closest_ doesn't handle it
    nil
  end

  # For subdivision, we still use geonames since geoBoundaries doesn't have neighborhood-level data
  # but we can add boundary context
  def subdivision_with_boundary_context
    geoname_result = closest_subdivision
    return geoname_result unless geoname_result
    
    # Add boundary context to help validate the subdivision
    boundaries = containing_boundaries(levels: %w[ADM2 ADM3 ADM4 ADM5])
    geoname_result.record.define_singleton_method(:containing_boundaries) { boundaries }
    
    geoname_result
  end

  # Find the metro area that contains this point using precise geometric containment
  #
  # This method uses PostGIS spatial operations to determine which metropolitan area
  # contains the current coordinate point. Metros are defined as collections of
  # geoboundaries (administrative boundaries) that together form a cohesive region.
  #
  # @return [Metro, nil] Metro area that contains this point, or nil if not within any metro
  #
  # @example
  #   listing.within_metro
  #   # => #<Metro id: 1, name: "Bay Area", details: "San Francisco Bay Area">
  #
  # @example
  #   listing.within_metro
  #   # => nil (if coordinates are not within any defined metro area)
  def within_metro
    return nil unless latitude && longitude

    # Direct spatial containment query - check if this point is within any metro's boundaries
    # MySQL spatial functions expect POINT(latitude longitude) format
    Metro.joins(:geoboundaries)
         .where("ST_Contains(geoboundaries.boundary, ST_GeomFromText(?, 4326))", "POINT(#{latitude} #{longitude})")
         .first
  end

  # Legacy method for backward compatibility - will be removed after migration
  # @deprecated Use {#within_metro} instead
  def closest_metro
    within_metro
  end

  # Compare geographic data from multiple sources for maintenance and debugging
  #
  # This method displays a side-by-side comparison of geographic attribute values from
  # different data sources: current stored values, GeoBoundaries.org data, and Geonames.org
  # data. Apps can extend this by overriding additional_source_columns to add their own
  # data sources (e.g., original API data).
  #
  # @return [String] Formatted comparison table or error message if no coordinates
  #
  # @example
  #   listing.compare_geo_sources
  #   # => Displays formatted table comparing all geographic attributes across sources
  def compare_geo_sources
    return "No coordinates available for comparison" unless latitude && longitude

    geo_attributes = %w[city county_or_parish state_or_province township subdivision_name country postal_code]
    
    # Collect all data first to avoid jumbled SQL output
    print "Collecting geographic data..."
    data_rows = []
    
    geo_attributes.each do |attr|
      print "."
      current_val = send(attr)
      boundary_val = get_boundary_value(attr)
      geoname_val = get_geoname_value(attr)
      
      # Get additional source columns from the implementing model
      additional_sources = respond_to?(:additional_source_columns, true) ? additional_source_columns(attr) : {}
      
      # Truncate long values for display
      current_display = truncate_value(current_val)
      boundary_display = truncate_value(boundary_val)
      geoname_display = truncate_value(geoname_val)
      
      # Check if current value differs from core sources and any additional sources
      all_source_vals = [boundary_val, geoname_val] + additional_sources.values
      marker = all_source_vals.none? { |val| current_val == val } ? " *" : ""
      
      row_data = {
        attr: attr.upcase,
        current: current_display || "(nil)",
        boundary: boundary_display || "(nil)",
        geoname: geoname_display || "(nil)",
        marker: marker
      }
      
      # Add additional source columns
      additional_sources.each do |column_name, value|
        row_data[column_name.to_sym] = truncate_value(value) || "(nil)"
      end
      
      data_rows << row_data
    end
    
    puts " done!\n"
    
    # Build header columns
    base_columns = %w[ATTRIBUTE CURRENT BOUNDARY GEONAMES]
    additional_columns = respond_to?(:additional_source_columns, true) ? 
      additional_source_columns(geo_attributes.first)&.keys || [] : []
    all_columns = base_columns + additional_columns.map(&:upcase)
    
    # Calculate total width
    total_width = all_columns.length * 20 + 4
    
    # Display results
    puts "\n" + "=" * total_width
    puts "GEO SOURCES COMPARISON"
    puts "Coordinates: #{latitude}, #{longitude}"
    puts "=" * total_width
    puts sprintf((["%-20s"] * all_columns.length).join(" "), *all_columns)
    puts "-" * (total_width + all_columns.length - 1)
    
    data_rows.each do |row|
      values = all_columns.map { |col| row[col.downcase.to_sym] }
      puts sprintf((["%-20s"] * values.length).join(" "), *values) + row[:marker]
    end
    
    puts "-" * (total_width + all_columns.length - 1)
    puts "* = Current value differs from all sources"
    puts "\nLegend:"
    puts "  CURRENT  - Value currently stored in database"
    puts "  BOUNDARY - Value from GeoBoundaries.org (precise polygon containment)"
    puts "  GEONAMES - Value from Geonames.org (nearest feature lookup)"
    
    # Add legend entries for additional sources
    if respond_to?(:additional_source_legend, true)
      additional_source_legend.each do |column, description|
        puts "  #{column.upcase.ljust(8)} - #{description}"
      end
    end
    
    puts "=" * total_width
    
    nil
  end

  # Validate and convert coordinates from radians to degrees if needed
  #
  # This method intelligently detects whether coordinates are provided in radians or degrees
  # using a multi-step validation process:
  #
  # 1. **Range Check**: If coordinates are outside degree ranges (|lat| > 90 or |lng| > 180),
  #    they are assumed to be radians and converted, unless they exceed reasonable bounds (> 1000)
  # 2. **Country Validation**: For ambiguous coordinates within degree ranges, attempts to
  #    validate against expected country boundaries using PostGIS spatial queries
  # 3. **Fallback**: If validation fails or PostGIS is unavailable, defaults to treating 
  #    coordinates as degrees
  #
  # This is particularly useful when dealing with data sources that may inconsistently
  # provide coordinates in different units.
  #
  # @param lat [Float, Integer] Latitude coordinate in degrees or radians
  # @param lng [Float, Integer] Longitude coordinate in degrees or radians
  # @param expected_country [String, nil] Optional 2-letter ISO country code (e.g., "US", "FR") 
  #   used for boundary validation when coordinates are ambiguous
  #
  # @return [Array<(Float, Float)>] Array containing [latitude, longitude] in degrees,
  #   or [nil, nil] if coordinates are invalid or outside reasonable bounds
  #
  # @example Converting obvious radians to degrees
  #   validate_and_convert_coordinates(0.7128, -1.2915, "US")
  #   # => [40.8355, -74.0060] (converted from radians using country validation)
  #
  # @example Preserving valid degrees
  #   validate_and_convert_coordinates(40.7128, -74.0060, "US") 
  #   # => [40.7128, -74.0060] (already in degrees, no conversion needed)
  #
  # @example Handling coordinates outside degree ranges
  #   validate_and_convert_coordinates(95.0, 1.5, "US")
  #   # => [5441.5, 85.9] (lat > 90°, so both coordinates converted from radians)
  #
  # @example Rejecting invalid coordinates
  #   validate_and_convert_coordinates(2000.0, 3000.0, "US")
  #   # => [nil, nil] (values too large to be reasonable coordinates)
  #
  # @note This method requires PostGIS tables (geoboundaries, geonames) for country validation.
  #   In test environments or when PostGIS is unavailable, country validation is skipped.
  #
  # @see #coordinates_match_country? for details on boundary validation logic
  # @since 1.0.0
  def validate_and_convert_coordinates(lat, lng, expected_country = nil)
    return [nil, nil] unless lat && lng
    
    lat = lat.to_f
    lng = lng.to_f
    
    # First check: are coordinates obviously in radians? (outside degree ranges)
    if lat.abs > 90 || lng.abs > 180
      # Check if they could be reasonable radians (not absurdly large)  
      # Reasonable upper bound: 1000 (much larger than any reasonable coordinate)
      if lat.abs <= 1000 && lng.abs <= 1000
        # Assume they are radians and convert
        lat_deg = lat * 180.0 / Math::PI
        lng_deg = lng * 180.0 / Math::PI
        return [lat_deg, lng_deg]
      else
        # Values too large to be reasonable coordinates in any format
        return [nil, nil]
      end
    end
    
    # Coordinates are within degree ranges - but could still be radians
    # Use country validation to determine which is correct
    if expected_country.present?
      # Test as degrees first
      degrees_valid = coordinates_match_country?(lat, lng, expected_country)
      
      # If degrees don't match, try converting from radians
      unless degrees_valid
        # Check if coordinates could be radians (within radian range)
        if lat.abs <= Math::PI && lng.abs <= Math::PI
          lat_from_radians = lat * 180.0 / Math::PI
          lng_from_radians = lng * 180.0 / Math::PI
          
          # Test if radians-to-degrees conversion matches expected country
          if coordinates_match_country?(lat_from_radians, lng_from_radians, expected_country)
            return [lat_from_radians, lng_from_radians]
          end
        end
      end
    end
    
    # Default: assume coordinates are already in degrees
    [lat, lng]
  end

  private

  # Check if coordinates fall within the expected country's boundaries
  #
  # This private method performs spatial validation by checking if the given coordinates
  # fall within the administrative boundaries of the expected country. It uses PostGIS
  # spatial containment queries against the GeoBoundaries.org dataset.
  #
  # The validation process:
  # 1. Validates coordinate ranges (lat: -90 to 90, lng: -180 to 180)
  # 2. Checks PostGIS table availability (gracefully handles test environments)
  # 3. Creates a temporary object with HasGeoLookup functionality for boundary lookup
  # 4. Converts country code from ISO2 to ISO3 format for geoboundary matching
  # 5. Checks if any containing boundary matches the expected country
  #
  # @param lat [Float] Latitude coordinate in degrees
  # @param lng [Float] Longitude coordinate in degrees  
  # @param country_code [String] 2-letter ISO country code (e.g., "US", "FR", "CA")
  #
  # @return [Boolean] true if coordinates fall within the expected country's boundaries,
  #   false otherwise or if validation fails
  #
  # @example Coordinates within expected country
  #   coordinates_match_country?(40.7128, -74.0060, "US")
  #   # => true (NYC coordinates are within USA boundaries)
  #
  # @example Coordinates outside expected country  
  #   coordinates_match_country?(48.8566, 2.3522, "US")
  #   # => false (Paris coordinates are not within USA boundaries)
  #
  # @example Invalid coordinate ranges
  #   coordinates_match_country?(200.0, -74.0, "US")
  #   # => false (latitude outside valid range)
  #
  # @note This method gracefully handles missing PostGIS tables by returning false,
  #   making it safe to use in test environments without spatial databases
  #
  # @note Requires the iso_3166 gem for country code conversion and GeoBoundaries
  #   data to be imported for the target country
  #
  # @see #containing_boundaries for the spatial containment logic
  # @see #postgis_tables_available? for PostGIS availability checking
  # @api private
  # @since 1.0.0
  def coordinates_match_country?(lat, lng, country_code)
    return false unless lat && lng && country_code
    
    # Quick range check first
    return false unless lat.between?(-90, 90) && lng.between?(-180, 180)
    
    # Only do boundary validation if PostGIS tables are available AND we're not in test environment
    if postgis_tables_available? && !Rails.env.test?
      # Use a temporary object to check boundaries
      temp_checker = Object.new
      temp_checker.define_singleton_method(:latitude) { lat }
      temp_checker.define_singleton_method(:longitude) { lng }
      temp_checker.extend(HasGeoLookup)
      
      # Look for any boundary in the expected country with error handling
      begin
        boundaries = temp_checker.containing_boundaries
        return false if boundaries.empty?
      rescue StandardError => e
        # If spatial queries fail, fall back to basic validation
        Rails.logger&.warn "Spatial validation failed: #{e.message}"
        return true  # Assume coordinates are valid if we can't verify
      end
      
      # Check if any boundary matches the expected country
      # Convert country code to ISO3 for geoboundary matching
      begin
        country_iso3 = Iso3166.for_code(country_code)&.code3
        return false unless country_iso3
        
        return boundaries.any? do |boundary|
          boundary.shape_iso&.include?(country_iso3) || 
          boundary.shape_group&.include?(country_iso3)
        end
      rescue => e
        # If geoboundary lookup fails, assume coordinates don't match
        return false
      end
    end
    
    # In test environment or if PostGIS unavailable, skip country validation
    # This means we'll default to treating coordinates as degrees
    false
  end

  # Check if PostGIS tables are available (for test environment handling)
  #
  # This helper method determines whether the required PostGIS tables (geoboundaries
  # and geonames) are available in the current database. It's primarily used to
  # gracefully handle test environments or deployments where spatial data hasn't
  # been imported yet.
  #
  # The method includes caching to avoid repeated database queries within the same
  # object instance.
  #
  # @return [Boolean] true if both 'geoboundaries' and 'geonames' tables exist
  #   and are accessible, false otherwise
  #
  # @example In a production environment with PostGIS data
  #   postgis_tables_available?
  #   # => true
  #
  # @example In a test environment without spatial tables
  #   postgis_tables_available?
  #   # => false
  #
  # @note This method catches and handles any database connection errors,
  #   returning false if the tables cannot be accessed for any reason
  #
  # @note The result is cached in @postgis_available to avoid repeated
  #   database queries during coordinate validation
  #
  # @api private
  # @since 1.0.0
  def postgis_tables_available?
    return @postgis_available if defined?(@postgis_available)
    @postgis_available = begin
      ActiveRecord::Base.connection.table_exists?('geoboundaries') &&
      ActiveRecord::Base.connection.table_exists?('geonames')
    rescue StandardError
      false
    end
  end

  # Get value from boundary sources
  def get_boundary_value(attr)
    case attr
    when 'county_or_parish'
      result = county_or_parish_boundary
      result&.record&.name rescue result&.name
    when 'state_or_province'
      result = state_or_province_boundary
      result&.record&.name rescue result&.name
    when 'township'
      result = township_boundary
      name = result&.record&.name rescue result&.name
      clean_municipal_name(name)
    when 'subdivision_name'
      result = subdivision_with_boundary_context
      result&.record&.name rescue nil
    else
      nil # Geoboundary data doesn't provide city, country, or postal_code
    end
  end

  # Get value from geoname sources
  def get_geoname_value(attr)
    case attr
    when 'county_or_parish'
      result = closest_county_or_parish
      result&.record&.name
    when 'township'
      result = closest_township
      result&.record&.name
    when 'subdivision_name'
      result = closest_subdivision
      result&.record&.name
    else
      nil # Geonames lookups are specific to administrative levels
    end
  end

  # Truncate long string values for display formatting
  #
  # @param value [Object] Value to truncate (will be converted to string)
  # @return [String, nil] Truncated string with "..." suffix if over 18 characters, or nil if input is nil
  #
  # @example
  #   truncate_value("This is a very long string")
  #   # => "This is a very l..."
  #
  # @example
  #   truncate_value("Short")
  #   # => "Short"
  def truncate_value(value)
    return nil unless value
    value = value.to_s
    value.length > 18 ? value[0..15] + "..." : value
  end

  # Clean municipal names by removing common prefixes and suffixes
  def clean_municipal_name(name)
    return nil unless name.present?
    
    cleaned = name.strip
    
    # Remove common prefixes (case-insensitive)
    prefixes = [
      'City of',
      'Borough of', 
      'Township of',
      'Town of',
      'Village of',
      'Municipality of',
      'County of',
      'District of'
    ]
    
    prefixes.each do |prefix|
      if cleaned.match?(/\A#{Regexp.escape(prefix)}\s+/i)
        cleaned = cleaned.sub(/\A#{Regexp.escape(prefix)}\s+/i, '')
        break
      end
    end
    
    # Remove common suffixes (case-insensitive)
    suffixes = [
      'City',
      'Borough',
      'Township', 
      'Town',
      'Village',
      'Municipality',
      'County',
      'District'
    ]
    
    suffixes.each do |suffix|
      if cleaned.match?(/\s+#{Regexp.escape(suffix)}\z/i) && 
         !cleaned.match?(/\A#{Regexp.escape(suffix)}\z/i) # Don't remove if it's the entire name
        cleaned = cleaned.sub(/\s+#{Regexp.escape(suffix)}\z/i, '')
        break
      end
    end
    
    cleaned.strip
  end

  def find_feature_class_and_code_by_keyword(keyword)
    FeatureCode
      .where("LOWER(name) LIKE :kw OR LOWER(description) LIKE :kw", kw: "%#{keyword.downcase}%")
      .limit(1)
      .pluck(:feature_class, :feature_code)
      .first
  end

  # Utilities for analyzing geographic data coverage and availability
  #
  # This module provides methods to check the availability of GeoBoundaries.org and
  # Geonames.org data for different countries. These utilities are gem-ready and 
  # don't depend on any specific application models or business logic.
  #
  # @example Check coverage for a country
  #   HasGeoLookup::DataCoverage.coverage_status('US')
  #   # => {boundaries: true, geonames: true, complete: true}
  #
  # @example Check individual data sources
  #   HasGeoLookup::DataCoverage.has_boundary_data?('FR')   # => true
  #   HasGeoLookup::DataCoverage.has_geonames_data?('FR')   # => false
  module DataCoverage
    extend self
    
    # Check if boundary data exists for a country
    # 
    # @param iso2 [String] 2-letter country code
    # @param level [String, nil] Optional specific ADM level to check (e.g., "ADM2")
    # @return [Boolean] true if boundary data exists
    def has_boundary_data?(iso2, level = nil)
      # Special cases for territories that don't have separate boundary data
      territories_without_boundaries = %w[PR VI GU AS MP TC] # US territories + others
      return true if territories_without_boundaries.include?(iso2)
      
      # Convert ISO2 to ISO3 to check boundaries
      country = Iso3166.for_code(iso2)
      return true unless country # If we can't convert, assume it exists to avoid infinite loops
      
      iso3 = country.code3
      
      # Build query for boundaries with optional level filter
      query = Geoboundary.where("shape_iso LIKE ? OR shape_group LIKE ?", "%#{iso3}%", "%#{iso3}%")
      query = query.where(level: level) if level
      
      query.exists?
    end
    
    # Get detailed boundary coverage by ADM level for a country
    #
    # @param iso2 [String] 2-letter country code
    # @return [Hash] Hash with ADM levels as keys and counts as values
    # @example
    #   boundary_coverage_by_level('US')
    #   # => { 'ADM1' => 51, 'ADM2' => 3142, 'ADM3' => 0, 'ADM4' => 0, 'ADM5' => 0 }
    def boundary_coverage_by_level(iso2)
      # Special cases for territories
      territories_without_boundaries = %w[PR VI GU AS MP TC]
      if territories_without_boundaries.include?(iso2)
        return %w[ADM1 ADM2 ADM3 ADM4 ADM5].index_with { |_| 1 } # Assume coverage
      end
      
      # Convert ISO2 to ISO3
      country = Iso3166.for_code(iso2)
      return {} unless country
      
      iso3 = country.code3
      
      # Count boundaries by level for this country
      boundaries_by_level = Geoboundary.where("shape_iso LIKE ? OR shape_group LIKE ?", "%#{iso3}%", "%#{iso3}%")
                                      .group(:level)
                                      .count
      
      # Ensure all ADM levels are represented (with 0 counts for missing)
      %w[ADM1 ADM2 ADM3 ADM4 ADM5].index_with do |level|
        boundaries_by_level[level] || 0
      end
    end
    
    # Get list of missing ADM levels for a country
    #
    # @param iso2 [String] 2-letter country code
    # @return [Array<String>] Array of missing ADM level strings
    # @example
    #   missing_adm_levels('US')
    #   # => ['ADM3', 'ADM4', 'ADM5']
    def missing_adm_levels(iso2)
      coverage = boundary_coverage_by_level(iso2)
      coverage.select { |_level, count| count == 0 }.keys
    end
    
    # Check if geonames data exists for a country
    #
    # @param iso2 [String] 2-letter country code  
    # @return [Boolean] true if geonames data exists
    def has_geonames_data?(iso2)
      # Special cases for territories that might not have separate geonames data
      territories_without_separate_geonames = %w[PR VI GU AS MP] # US territories
      return true if territories_without_separate_geonames.include?(iso2)
      
      # Check if we have geonames data for this country
      Geoname.where(country_code: iso2).exists?
    end
    
    # Get comprehensive coverage status for a country
    #
    # @param iso2 [String] 2-letter country code
    # @return [Hash] Coverage status with detailed boundary information
    # @example
    #   coverage_status('US')
    #   # => {
    #   #   boundaries: true,
    #   #   geonames: true,
    #   #   complete: false,
    #   #   boundary_coverage: { 'ADM1' => 51, 'ADM2' => 3142, 'ADM3' => 0, 'ADM4' => 0, 'ADM5' => 0 },
    #   #   missing_adm_levels: ['ADM3', 'ADM4', 'ADM5']
    #   # }
    def coverage_status(iso2)
      boundaries = has_boundary_data?(iso2)
      geonames = has_geonames_data?(iso2)
      boundary_coverage = boundary_coverage_by_level(iso2)
      missing_levels = missing_adm_levels(iso2)
      
      {
        boundaries: boundaries,
        geonames: geonames, 
        complete: boundaries && geonames && missing_levels.empty?,
        boundary_coverage: boundary_coverage,
        missing_adm_levels: missing_levels
      }
    end
    
  end
end