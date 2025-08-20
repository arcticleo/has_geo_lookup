# frozen_string_literal: true

# Geoname model for geographic place names from Geonames.org
#
# This model represents geographic features from the Geonames.org dataset, which provides
# comprehensive information about populated places, administrative divisions, and geographic
# features worldwide. Each record includes coordinates, names, administrative codes, and
# feature classifications.
#
# The Geonames dataset is organized using feature classes and codes that categorize
# different types of geographic entities (populated places, administrative areas,
# hydrographic features, etc.).
#
# @example Find populated places in the US
#   Geoname.where(country_code: "US", feature_class: "P")
#
# @example Find administrative divisions
#   Geoname.where(feature_class: "A", feature_code: "ADM2")
#
# @see https://www.geonames.org/ Official Geonames website
# @see FeatureCode For feature classification definitions
class Geoname < ActiveRecord::Base
  include HasGeoLookup

  # Associations
  has_and_belongs_to_many :metros

  # Validations
  validates :name, presence: true
  validates :latitude, :longitude, presence: true, numericality: true
  validates :feature_class, presence: true, length: { is: 1 }
  validates :feature_code, presence: true, length: { maximum: 10 }
  validates :country_code, length: { is: 2 }, allow_blank: true
  validates :population, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :elevation, numericality: true, allow_nil: true

  # Scopes for common queries
  scope :populated_places, -> { where(feature_class: "P") }
  scope :administrative, -> { where(feature_class: "A") }
  scope :hydrographic, -> { where(feature_class: "H") }
  scope :terrain, -> { where(feature_class: "T") }
  scope :roads_railways, -> { where(feature_class: "R") }
  scope :spots_buildings, -> { where(feature_class: "S") }
  scope :undersea, -> { where(feature_class: "U") }
  scope :vegetation, -> { where(feature_class: "V") }

  scope :by_country, ->(country_code) { where(country_code: country_code.upcase) }
  scope :with_population, -> { where.not(population: [nil, 0]) }
  scope :major_places, -> { with_population.where("population > ?", 100000) }

  # Geographic bounds scopes
  scope :within_bounds, ->(north, south, east, west) {
    where(latitude: south..north, longitude: west..east)
  }

  scope :near_coordinates, ->(lat, lng, radius_deg = 1.0) {
    where(
      latitude: (lat - radius_deg)..(lat + radius_deg),
      longitude: (lng - radius_deg)..(lng + radius_deg)
    )
  }

  # Calculate distance to coordinates using Haversine formula
  #
  # This method calculates the great-circle distance between this geoname's coordinates
  # and the provided coordinates using the Haversine formula. Useful for finding nearby
  # places or sorting by distance.
  #
  # @param target_lat [Float] Target latitude in degrees
  # @param target_lng [Float] Target longitude in degrees
  # @return [Float] Distance in kilometers
  #
  # @example
  #   geoname.distance_to(40.7128, -74.0060)
  #   # => 245.67 (distance in kilometers)
  def distance_to(target_lat, target_lng)
    return nil unless latitude && longitude && target_lat && target_lng

    # Haversine formula
    radius_km = 6371.0
    lat1_rad = latitude * Math::PI / 180
    lat2_rad = target_lat * Math::PI / 180
    delta_lat_rad = (target_lat - latitude) * Math::PI / 180
    delta_lng_rad = (target_lng - longitude) * Math::PI / 180

    a = Math.sin(delta_lat_rad / 2) * Math.sin(delta_lat_rad / 2) +
        Math.cos(lat1_rad) * Math.cos(lat2_rad) *
        Math.sin(delta_lng_rad / 2) * Math.sin(delta_lng_rad / 2)
    
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    radius_km * c
  end

  # Returns a human-readable description of this place
  #
  # Combines the name with administrative context and country information to provide
  # a comprehensive description suitable for display or logging.
  #
  # @return [String] Formatted description
  #
  # @example
  #   geoname.display_name
  #   # => "New York, New York, US (PPL - populated place)"
  def display_name
    parts = [name]
    parts << admin1_name if admin1_name.present?
    parts << admin2_name if admin2_name.present? && admin2_name != admin1_name
    parts << country_code if country_code.present?
    
    description = parts.join(", ")
    
    if feature_code.present?
      description += " (#{feature_code})"
    end
    
    description
  end

  # Check if this is a populated place
  # @return [Boolean] true if feature_class is "P"
  def populated_place?
    feature_class == "P"
  end

  # Check if this is an administrative division
  # @return [Boolean] true if feature_class is "A"
  def administrative_division?
    feature_class == "A"
  end

  # Get the administrative level for administrative divisions
  # @return [String, nil] Administrative level (ADM1, ADM2, etc.) or nil
  def administrative_level
    return nil unless administrative_division?
    feature_code if feature_code&.start_with?("ADM")
  end

  # Ensure country codes are stored in uppercase
  def country_code=(value)
    super(value&.upcase)
  end

  # Ensure feature class is stored in uppercase
  def feature_class=(value)
    super(value&.upcase)
  end

  # Ensure feature code is stored in uppercase
  def feature_code=(value)
    super(value&.upcase)
  end
end