# frozen_string_literal: true

# Feature classification codes for geographic places from Geonames.org
#
# This model stores the feature classification system used by Geonames.org to categorize
# different types of geographic features. Each feature code belongs to a feature class
# and provides detailed categorization for places, administrative divisions, hydrographic
# features, terrain features, etc.
#
# Feature classes include:
# - A: Administrative divisions (countries, states, counties)
# - P: Populated places (cities, towns, villages)
# - H: Hydrographic features (rivers, lakes, seas)
# - T: Terrain features (mountains, hills, valleys)
# - R: Roads and railways
# - S: Spots and buildings (schools, churches, stations)
# - U: Undersea features
# - V: Vegetation features (forests, parks)
# - L: Localities and areas
#
# @attr [String] feature_class Single letter feature class (A, P, H, T, R, S, U, V, L)
# @attr [String] feature_code Specific feature code (e.g., PPL, ADM1, RIV, MT)
# @attr [String] name Human-readable name of the feature type
# @attr [String] description Detailed description of what this feature represents
#
# @example Find administrative division codes
#   FeatureCode.where(feature_class: "A")
#
# @example Find populated place codes
#   FeatureCode.where(feature_class: "P")
#
# @see https://www.geonames.org/export/codes.html Geonames feature codes documentation
class FeatureCode < ActiveRecord::Base
  # Simple model - no associations for now

  # Validations
  validates :feature_class, presence: true, length: { is: 1 }
  validates :feature_code, presence: true, length: { maximum: 10 }
  validates :name, presence: true

  # Ensure uniqueness of feature_class + feature_code combination
  validates :feature_code, uniqueness: { scope: :feature_class }

  # Scopes for different feature classes
  scope :administrative, -> { where(feature_class: "A") }
  scope :populated_places, -> { where(feature_class: "P") }
  scope :hydrographic, -> { where(feature_class: "H") }
  scope :terrain, -> { where(feature_class: "T") }
  scope :roads_railways, -> { where(feature_class: "R") }
  scope :spots_buildings, -> { where(feature_class: "S") }
  scope :undersea, -> { where(feature_class: "U") }
  scope :vegetation, -> { where(feature_class: "V") }
  scope :localities, -> { where(feature_class: "L") }

  # Search scopes
  scope :by_keyword, ->(keyword) {
    where("LOWER(name) LIKE :keyword OR LOWER(description) LIKE :keyword", 
          keyword: "%#{keyword.to_s.downcase}%")
  }

  scope :administrative_levels, -> {
    where(feature_class: "A").where("feature_code LIKE 'ADM%'").order(:feature_code)
  }

  # Class methods for common feature code lookups

  # Find feature codes matching a search term
  #
  # Searches both the name and description fields for the given keyword,
  # useful for finding appropriate feature codes when you know the type
  # of place but not the exact code.
  #
  # @param keyword [String] Search term to match against name and description
  # @return [ActiveRecord::Relation] Matching feature codes
  #
  # @example
  #   FeatureCode.search("county")
  #   # => Returns feature codes related to counties
  #
  # @example
  #   FeatureCode.search("populated")
  #   # => Returns feature codes for populated places
  def self.search(keyword)
    by_keyword(keyword)
  end

  # Get all administrative division levels
  #
  # Returns all ADM (administrative) feature codes ordered by level,
  # useful for understanding the administrative hierarchy.
  #
  # @return [Array<FeatureCode>] Administrative division feature codes
  #
  # @example
  #   FeatureCode.admin_levels
  #   # => [ADM0 (countries), ADM1 (states), ADM2 (counties), etc.]
  def self.admin_levels
    administrative_levels.to_a
  end

  # Find the most appropriate feature code for a keyword
  #
  # Returns the first feature code that matches the keyword, prioritizing
  # exact name matches over description matches.
  #
  # @param keyword [String] Search term
  # @return [FeatureCode, nil] Best matching feature code or nil
  #
  # @example
  #   FeatureCode.find_by_keyword("county")
  #   # => #<FeatureCode feature_class: "A", feature_code: "ADM2", name: "second-order administrative division">
  def self.find_by_keyword(keyword)
    return nil if keyword.blank?
    
    # First try exact name match
    exact_match = where("LOWER(name) = ?", keyword.to_s.downcase).first
    return exact_match if exact_match
    
    # Then try partial matches
    by_keyword(keyword).first
  end

  # Instance methods

  # Returns the full feature identifier
  #
  # Combines feature class and feature code into a single identifier
  # string for display or logging purposes.
  #
  # @return [String] Combined feature class and code
  #
  # @example
  #   feature_code.full_code
  #   # => "P.PPL" (for populated place)
  def full_code
    "#{feature_class}.#{feature_code}"
  end

  # Returns a human-readable description
  #
  # Combines the name and description with the feature code for
  # comprehensive identification.
  #
  # @return [String] Formatted description
  #
  # @example
  #   feature_code.display_name
  #   # => "ADM2 - second-order administrative division (county, district)"
  def display_name
    "#{feature_code} - #{name}"
  end

  # Check if this represents an administrative division
  # @return [Boolean] true if feature_class is "A"
  def administrative?
    feature_class == "A"
  end

  # Check if this represents a populated place
  # @return [Boolean] true if feature_class is "P"
  def populated_place?
    feature_class == "P"
  end

  # Check if this represents a hydrographic feature
  # @return [Boolean] true if feature_class is "H"
  def hydrographic?
    feature_class == "H"
  end

  # Check if this represents a terrain feature
  # @return [Boolean] true if feature_class is "T"
  def terrain?
    feature_class == "T"
  end

  # Get the administrative level for administrative features
  # @return [Integer, nil] Administrative level (0-4) or nil for non-administrative features
  def admin_level
    return nil unless administrative? && feature_code.start_with?("ADM")
    
    level_match = feature_code.match(/ADM(\d)/)
    level_match ? level_match[1].to_i : nil
  end

  # Ensure feature class and code are stored in uppercase
  def feature_class=(value)
    super(value&.upcase)
  end

  def feature_code=(value)
    super(value&.upcase)
  end
end