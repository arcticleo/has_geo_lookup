# frozen_string_literal: true

# Metropolitan areas defined by collections of administrative boundaries
#
# This model represents metropolitan areas (metro areas, urban agglomerations) as
# collections of administrative boundaries from GeoBoundaries.org. Rather than storing
# separate geometry, metros are defined by their constituent geoboundaries, allowing
# for flexible and maintainable metro definitions.
#
# Metro areas are useful for:
# - Real estate market analysis by metropolitan region
# - Economic data aggregation across municipal boundaries  
# - Transportation and infrastructure planning
# - Population and demographic analysis
#
# Each metro can span multiple administrative levels and boundaries, reflecting
# the real-world nature of metropolitan areas that often cross county, city,
# and sometimes state boundaries.
#
# @attr [String] name Metro area name (e.g., "San Francisco Bay Area", "Greater London")
# @attr [String] details Additional descriptive information about the metro
# @attr [String] country_code Primary country code for this metro area
# @attr [Integer] population Estimated metro population (optional)
#
# @example Find metros containing a point
#   Metro.joins(:geoboundaries)
#        .where("ST_Contains(geoboundaries.boundary, ST_GeomFromText(?, 4326))", "POINT(-122.4194 37.7749)")
#
# @example Find metros in a specific country  
#   Metro.where(country_code: "US")
class Metro < ActiveRecord::Base
  # Associations
  has_and_belongs_to_many :geoboundaries

  # Validations
  validates :name, presence: true, uniqueness: true
  validates :country_code, length: { is: 2 }, allow_blank: true
  validates :population, numericality: { greater_than: 0 }, allow_nil: true

  # Scopes
  scope :by_country, ->(country_code) { where(country_code: country_code.upcase) }
  scope :with_population, -> { where.not(population: nil) }
  scope :major_metros, -> { with_population.where("population > ?", 1_000_000) }

  scope :containing_point, ->(latitude, longitude) {
    joins(:geoboundaries)
    .where("ST_Contains(geoboundaries.boundary, ST_GeomFromText(?, 4326))", 
           "POINT(#{latitude} #{longitude})")
    .distinct
  }

  # Check if this metro contains the given coordinates
  #
  # Uses MySQL spatial queries against all associated geoboundaries to determine
  # if the point falls within any boundary that defines this metropolitan area.
  #
  # @param latitude [Float] Latitude in decimal degrees
  # @param longitude [Float] Longitude in decimal degrees
  # @return [Boolean] true if the point is within this metro area
  #
  # @example
  #   metro.contains_point?(37.7749, -122.4194)
  #   # => true (if coordinates are within San Francisco Bay Area)
  def contains_point?(latitude, longitude)
    return false unless latitude && longitude
    return false unless geoboundaries.any?

    # Check if point is contained within any of the metro's boundaries
    geoboundaries.joins("INNER JOIN geoboundaries gb ON gb.id = geoboundaries.id")
                 .where("ST_Contains(gb.boundary, ST_GeomFromText(?, 4326))", 
                        "POINT(#{latitude} #{longitude})")
                 .exists?
  rescue => e
    Rails.logger.warn "Error checking metro point containment: #{e.message}"
    false
  end

  # Calculate the total area of this metro in square kilometers
  #
  # Sums the areas of all constituent geoboundaries, with handling for
  # overlapping boundaries to avoid double-counting.
  #
  # @return [Float, nil] Total area in square kilometers, or nil if no boundaries
  #
  # @example
  #   metro.total_area_km2
  #   # => 18040.5 (total metro area in square kilometers)
  def total_area_km2
    return nil unless geoboundaries.any?

    # Calculate total area using ST_Union to handle overlapping boundaries
    result = self.class.connection.select_value(<<~SQL.squish)
      SELECT ST_Area(ST_Transform(ST_Union(boundary), 3857)) / 1000000 AS total_area_km2
      FROM geoboundaries 
      WHERE id IN (#{geoboundary_ids.join(',')})
    SQL

    result&.round(2)
  rescue => e
    Rails.logger.warn "Error calculating metro area: #{e.message}"
    nil
  end

  # Get the geographic center (centroid) of this metro
  #
  # Calculates the centroid of all constituent boundaries combined,
  # providing a representative center point for the metropolitan area.
  #
  # @return [Array<Float>, nil] [latitude, longitude] of metro center, or nil if error
  #
  # @example
  #   metro.centroid
  #   # => [37.4419, -122.1430] (lat, lng of metro center)
  def centroid
    return nil unless geoboundaries.any?

    result = self.class.connection.select_one(<<~SQL.squish)
      SELECT 
        ST_Y(ST_Centroid(ST_Union(boundary))) AS lat,
        ST_X(ST_Centroid(ST_Union(boundary))) AS lng
      FROM geoboundaries 
      WHERE id IN (#{geoboundary_ids.join(',')})
    SQL

    result ? [result['lat'].to_f, result['lng'].to_f] : nil
  rescue => e
    Rails.logger.warn "Error calculating metro centroid: #{e.message}"
    nil
  end

  # Get all boundary names that define this metro
  #
  # Returns a list of all constituent boundary names for understanding
  # the geographic composition of this metropolitan area.
  #
  # @return [Array<String>] Array of boundary names
  #
  # @example
  #   metro.boundary_names
  #   # => ["San Francisco County", "Alameda County", "Santa Clara County", ...]
  def boundary_names
    geoboundaries.pluck(:name).compact.sort
  end

  # Get administrative levels represented in this metro
  #
  # Returns the different administrative levels (ADM1, ADM2, etc.) that
  # make up this metropolitan area.
  #
  # @return [Array<String>] Array of administrative levels
  #
  # @example
  #   metro.admin_levels
  #   # => ["ADM1", "ADM2"] (includes state and county level boundaries)
  def admin_levels
    geoboundaries.distinct.pluck(:level).compact.sort
  end

  # Check if this metro spans multiple states/provinces
  #
  # Determines if the metro includes boundaries from multiple ADM1
  # (state/province) level divisions.
  #
  # @return [Boolean] true if metro spans multiple states/provinces
  #
  # @example
  #   metro.multi_state?
  #   # => true (if metro crosses state boundaries)
  def multi_state?
    state_boundaries = geoboundaries.where(level: "ADM1")
    state_boundaries.count > 1
  end

  # Get population density (people per km²)
  #
  # Calculates population density based on total population and area,
  # if both values are available.
  #
  # @return [Float, nil] Population density in people per km², or nil if data unavailable
  #
  # @example
  #   metro.population_density
  #   # => 1547.3 (people per square kilometer)
  def population_density
    return nil unless population && total_area_km2
    return nil if total_area_km2.zero?
    
    (population.to_f / total_area_km2).round(1)
  end

  # Returns a human-readable description of this metro
  #
  # Combines name, details, country, and constituent boundary information
  # for comprehensive metro identification.
  #
  # @return [String] Formatted description
  #
  # @example
  #   metro.display_name
  #   # => "San Francisco Bay Area (US) - 9 counties, 2 admin levels"
  def display_name
    parts = [name]
    parts << "(#{country_code})" if country_code.present?
    
    if geoboundaries.any?
      boundary_count = geoboundaries.count
      level_count = admin_levels.count
      parts << "#{boundary_count} boundaries, #{level_count} admin level#{'s' if level_count != 1}"
    end
    
    description = parts.join(" - ")
    description += "\n#{details}" if details.present?
    description
  end

  # Ensure country code is stored in uppercase
  def country_code=(value)
    super(value&.upcase)
  end

  # Get a summary of this metro's geographic composition
  #
  # Returns detailed information about the boundaries and administrative
  # levels that make up this metropolitan area.
  #
  # @return [Hash] Summary with boundary counts by level and names
  #
  # @example
  #   metro.geographic_summary
  #   # => {
  #   #   total_boundaries: 9,
  #   #   by_level: {"ADM1" => 1, "ADM2" => 8},
  #   #   boundary_names: ["San Francisco County", "Alameda County", ...],
  #   #   spans_multiple_states: false
  #   # }
  def geographic_summary
    {
      total_boundaries: geoboundaries.count,
      by_level: geoboundaries.group(:level).count,
      boundary_names: boundary_names,
      spans_multiple_states: multi_state?,
      admin_levels: admin_levels,
      total_area_km2: total_area_km2,
      population_density: population_density
    }
  end
end