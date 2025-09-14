# frozen_string_literal: true

# Administrative boundary geometries from GeoBoundaries.org
#
# This model stores precise administrative boundary polygons from GeoBoundaries.org,
# providing accurate geometric shapes for countries, states, counties, and municipalities
# worldwide. Each boundary includes PostGIS geometry data for spatial queries and
# containment testing.
#
# GeoBoundaries provides multiple administrative levels:
# - ADM0: Country boundaries
# - ADM1: State/province boundaries (e.g., California, Ontario)
# - ADM2: County/district boundaries (e.g., Los Angeles County)
# - ADM3: Municipality boundaries (e.g., city limits)
# - ADM4: Neighborhood/ward boundaries
# - ADM5: Sub-neighborhood boundaries (city blocks, micro-districts)
#
# The boundary geometries are stored using PostGIS and can be used for precise
# point-in-polygon queries to determine administrative containment.
#
# @attr [String] name Official boundary name
# @attr [String] level Administrative level (ADM0, ADM1, ADM2, ADM3, ADM4, ADM5)
# @attr [String] shape_iso ISO3 country code for this boundary
# @attr [String] shape_group Grouping identifier for related boundaries
# @attr [RGeo::Geos::CAPIGeometryMethods] boundary PostGIS geometry (polygon/multipolygon)
#
# @example Find boundaries containing a point
#   Geoboundary.where("ST_Contains(boundary, ST_GeomFromText('POINT(-74.0060 40.7128)', 4326))")
#
# @example Find state-level boundaries for the US
#   Geoboundary.where(level: "ADM1").where("shape_iso LIKE '%USA%'")
#
# @see https://www.geoboundaries.org GeoBoundaries.org data source
class Geoboundary < ActiveRecord::Base
  # Associations
  has_and_belongs_to_many :metros

  # Validations
  validates :name, presence: true
  validates :level, presence: true, inclusion: { in: %w[ADM0 ADM1 ADM2 ADM3 ADM4 ADM5] }
  validates :boundary, presence: true

  # Scopes for different administrative levels
  scope :countries, -> { where(level: "ADM0") }
  scope :states_provinces, -> { where(level: "ADM1") }
  scope :counties_districts, -> { where(level: "ADM2") }
  scope :municipalities, -> { where(level: "ADM3") }
  scope :neighborhoods, -> { where(level: "ADM4") }
  scope :sub_neighborhoods, -> { where(level: "ADM5") }

  scope :by_country, ->(country_code) {
    iso3 = country_code_to_iso3(country_code)
    where("shape_iso LIKE ? OR shape_group LIKE ?", "%#{iso3}%", "%#{iso3}%") if iso3
  }

  scope :containing_point, ->(latitude, longitude) {
    where("ST_Contains(boundary, ST_GeomFromText(?, 4326))", "POINT(#{latitude} #{longitude})")
  }

  # Check if this boundary contains the given coordinates
  #
  # Uses MySQL ST_Contains function to perform precise geometric containment
  # testing against the boundary polygon.
  #
  # @param latitude [Float] Latitude in decimal degrees
  # @param longitude [Float] Longitude in decimal degrees
  # @return [Boolean] true if the point is within this boundary
  #
  # @example
  #   boundary.contains_point?(40.7128, -74.0060)
  #   # => true (if NYC coordinates are within this boundary)
  def contains_point?(latitude, longitude)
    return false unless latitude && longitude && boundary
    
    point_wkt = "POINT(#{latitude} #{longitude})"
    
    self.class.connection.select_value(
      "SELECT ST_Contains(ST_GeomFromText(?), ST_GeomFromText(?, 4326)) AS contains",
      boundary.to_s, point_wkt
    ) == 1
  rescue => e
    Rails.logger.warn "Error checking point containment: #{e.message}"
    false
  end

  # Calculate the area of this boundary in square kilometers
  #
  # Uses PostGIS ST_Area function with spheroid calculations for accurate
  # area computation on the Earth's surface.
  #
  # @return [Float] Area in square kilometers
  #
  # @example
  #   boundary.area_km2
  #   # => 10991.5 (area in square kilometers)
  def area_km2
    return nil unless boundary
    
    area_m2 = self.class.connection.select_value(
      "SELECT ST_Area(ST_Transform(ST_GeomFromText(?), 3857))", 
      boundary.to_s
    )
    
    area_m2 ? (area_m2 / 1_000_000).round(2) : nil
  rescue => e
    Rails.logger.warn "Error calculating boundary area: #{e.message}"
    nil
  end

  # Get the centroid (center point) of this boundary
  #
  # Uses PostGIS ST_Centroid function to find the geometric center
  # of the boundary polygon.
  #
  # @return [Array<Float>, nil] [latitude, longitude] of centroid, or nil if error
  #
  # @example
  #   boundary.centroid
  #   # => [40.7589, -73.9851] (lat, lng of boundary center)
  def centroid
    return nil unless boundary
    
    result = self.class.connection.select_one(
      "SELECT ST_Y(ST_Centroid(ST_GeomFromText(?))) AS lat, ST_X(ST_Centroid(ST_GeomFromText(?))) AS lng",
      boundary.to_s, boundary.to_s
    )
    
    result ? [result['lat'].to_f, result['lng'].to_f] : nil
  rescue => e
    Rails.logger.warn "Error calculating boundary centroid: #{e.message}"
    nil
  end

  # Returns a human-readable description of this boundary
  #
  # Includes the boundary name, administrative level, and country context
  # for clear identification.
  #
  # @return [String] Formatted description
  #
  # @example
  #   boundary.display_name
  #   # => "Los Angeles County (ADM2 - County/District, USA)"
  def display_name
    level_description = case level
    when "ADM0" then "Country"
    when "ADM1" then "State/Province"
    when "ADM2" then "County/District"
    when "ADM3" then "Municipality"
    when "ADM4" then "Neighborhood/Ward"
    when "ADM5" then "Sub-Neighborhood/Block"
    else level
    end
    
    country_info = extract_country_from_shape_iso
    country_suffix = country_info ? ", #{country_info}" : ""
    
    "#{name} (#{level} - #{level_description}#{country_suffix})"
  end

  # Check if this is a country-level boundary
  # @return [Boolean] true if level is "ADM0"
  def country?
    level == "ADM0"
  end

  # Check if this is a state/province-level boundary
  # @return [Boolean] true if level is "ADM1"
  def state_province?
    level == "ADM1"
  end

  # Check if this is a county/district-level boundary
  # @return [Boolean] true if level is "ADM2"
  def county_district?
    level == "ADM2"
  end

  # Check if this is a municipality-level boundary
  # @return [Boolean] true if level is "ADM3"
  def municipality?
    level == "ADM3"
  end

  # Check if this is a neighborhood-level boundary
  # @return [Boolean] true if level is "ADM4"
  def neighborhood?
    level == "ADM4"
  end

  # Check if this is a sub-neighborhood-level boundary
  # @return [Boolean] true if level is "ADM5"
  def sub_neighborhood?
    level == "ADM5"
  end

  private

  # Convert 2-letter country code to 3-letter ISO3 code
  def self.country_code_to_iso3(country_code)
    return nil unless country_code&.length == 2
    
    begin
      country = Iso3166.for_code(country_code.upcase)
      country&.code3
    rescue
      nil
    end
  end

  # Extract country information from shape_iso field
  def extract_country_from_shape_iso
    return nil unless shape_iso.present?
    
    # shape_iso often contains patterns like "USA-ADM1" or similar
    # Extract the country code portion
    country_match = shape_iso.match(/([A-Z]{3})/)
    return nil unless country_match
    
    iso3_code = country_match[1]
    
    begin
      country = Iso3166.for_alpha3(iso3_code)
      country&.name
    rescue
      iso3_code
    end
  end
end