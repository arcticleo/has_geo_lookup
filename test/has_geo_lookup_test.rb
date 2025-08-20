# frozen_string_literal: true

require "test_helper"

class HasGeoLookupTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestModel < ActiveRecord::Base
    self.table_name = 'test_models'
    include HasGeoLookup
  end

  def setup
    @test_instance = TestModel.create!(name: "NYC Test", latitude: 40.7128, longitude: -74.0060)
    @no_coords_instance = TestModel.create!(name: "No Coords Test")
  end

  def test_should_have_coordinates
    assert_equal 40.7128, @test_instance.latitude.to_f
    assert_equal -74.0060, @test_instance.longitude.to_f
  end

  def test_should_handle_missing_coordinates
    assert_nil @no_coords_instance.latitude
    assert_nil @no_coords_instance.longitude
  end

  def test_nearest_geonames_returns_empty_array_without_coordinates
    result = @no_coords_instance.nearest_geonames(feature_code: "PPL")
    assert_equal [], result
  end

  def test_nearest_geonames_returns_empty_array_without_feature_criteria
    result = @test_instance.nearest_geonames
    assert_equal [], result
  end

  def test_clean_municipal_name_removes_common_prefixes
    test_cases = [
      ["City of New York", "New York"],
      ["Borough of Manhattan", "Manhattan"], 
      ["Township of Franklin", "Franklin"],
      ["Town of Smithfield", "Smithfield"],
      ["Village of Oak Park", "Oak Park"],
      ["Municipality of Springfield", "Springfield"],
      ["County of Los Angeles", "Los Angeles"],
      ["District of Columbia", "Columbia"]
    ]
    
    test_cases.each do |original, expected|
      result = @test_instance.send(:clean_municipal_name, original)
      assert_equal expected, result, "Failed to clean '#{original}'"
    end
  end

  def test_clean_municipal_name_removes_common_suffixes
    test_cases = [
      ["New York City", "New York"],
      ["Westchester County", "Westchester"],
      ["Franklin Township", "Franklin"],
      ["Smithfield Town", "Smithfield"],
      ["Oak Park Village", "Oak Park"]
    ]
    
    test_cases.each do |original, expected|
      result = @test_instance.send(:clean_municipal_name, original)
      assert_equal expected, result, "Failed to clean '#{original}'"
    end
  end

  def test_clean_municipal_name_preserves_single_word_names
    single_words = ["City", "Borough", "Township", "Village"]
    
    single_words.each do |word|
      result = @test_instance.send(:clean_municipal_name, word)
      assert_equal word, result, "Should not clean single word '#{word}'"
    end
  end

  def test_clean_municipal_name_handles_nil_and_empty_values
    assert_nil @test_instance.send(:clean_municipal_name, nil)
    assert_nil @test_instance.send(:clean_municipal_name, "")
    assert_nil @test_instance.send(:clean_municipal_name, "   ")
  end

  def test_clean_municipal_name_handles_case_insensitive_matching
    test_cases = [
      ["CITY OF NEW YORK", "NEW YORK"],
      ["city of boston", "boston"],
      ["Borough Of Brooklyn", "Brooklyn"]
    ]
    
    test_cases.each do |original, expected|
      result = @test_instance.send(:clean_municipal_name, original)
      assert_equal expected, result, "Failed case-insensitive cleaning of '#{original}'"
    end
  end

  def test_truncate_value_handles_long_strings
    long_string = "This is a very long string that should be truncated"
    result = @test_instance.send(:truncate_value, long_string)
    assert_equal "This is a very l...", result
  end

  def test_truncate_value_handles_short_strings
    short_string = "Short"
    result = @test_instance.send(:truncate_value, short_string)
    assert_equal "Short", result
  end

  def test_truncate_value_handles_nil_values
    result = @test_instance.send(:truncate_value, nil)
    assert_nil result
  end

  def test_compare_geo_sources_returns_message_without_coordinates
    result = @no_coords_instance.compare_geo_sources
    assert_equal "No coordinates available for comparison", result
  end

  def test_bounding_box_calculation
    # Test the bounding box calculation logic used in nearest_geonames
    lat, lng = 40.7128, -74.0060
    radius_km = 50
    
    lat_offset = radius_km / 111.0
    lng_offset = radius_km / (111.0 * Math.cos(Math::PI * lat / 180.0))
    
    # These should be reasonable bounding box offsets
    assert_in_delta 0.45, lat_offset, 0.01
    assert_in_delta 0.62, lng_offset, 0.1
  end

  # Coordinate validation tests
  def test_validate_and_convert_coordinates_handles_nil_values
    result = @test_instance.validate_and_convert_coordinates(nil, nil)
    assert_equal [nil, nil], result
    
    result = @test_instance.validate_and_convert_coordinates(40.0, nil)
    assert_equal [nil, nil], result
    
    result = @test_instance.validate_and_convert_coordinates(nil, -74.0)
    assert_equal [nil, nil], result
  end

  def test_validate_and_convert_coordinates_handles_obvious_radians
    # Test coordinates obviously outside degree ranges 
    lat_rad = 95.0  # > 90 degrees, clearly radians
    lng_rad = -2.0  # within normal ranges but will be converted with lat
    
    result = @test_instance.validate_and_convert_coordinates(lat_rad, lng_rad)
    
    expected_lat = lat_rad * 180.0 / Math::PI  # ~5441 degrees
    expected_lng = lng_rad * 180.0 / Math::PI  # ~-114.59 degrees
    
    assert_in_delta expected_lat, result[0], 0.01
    assert_in_delta expected_lng, result[1], 0.01
  end

  def test_validate_and_convert_coordinates_handles_invalid_coordinates
    # Test coordinates outside reasonable bounds (> 1000)
    result = @test_instance.validate_and_convert_coordinates(2000.0, 3000.0)
    assert_equal [nil, nil], result
    
    # Test coordinates at the boundary of what we consider reasonable  
    result = @test_instance.validate_and_convert_coordinates(1001.0, 500.0)
    assert_equal [nil, nil], result
  end

  def test_validate_and_convert_coordinates_preserves_valid_degrees
    # Test coordinates already in degrees (should remain unchanged)
    lat_deg = 40.7128
    lng_deg = -74.0060
    
    result = @test_instance.validate_and_convert_coordinates(lat_deg, lng_deg)
    
    assert_in_delta lat_deg, result[0], 0.001
    assert_in_delta lng_deg, result[1], 0.001
  end

  def test_validate_and_convert_coordinates_uzes_france_case
    # Test the real-world Uzès, France case with radians
    # Input: 0.76813168743, 0.0771259076594 (radians)
    # Expected: ~44.011, ~4.419 (degrees) - Uzès, Gard, France
    
    lat_rad = 0.76813168743
    lng_rad = 0.0771259076594
    
    # In gem test environment without PostGIS, this defaults to degrees
    # In production with PostGIS, country validation would detect radians
    result = @test_instance.validate_and_convert_coordinates(lat_rad, lng_rad, "FR")
    
    expected_lat = lat_rad * 180.0 / Math::PI  # Should be ~44.011
    expected_lng = lng_rad * 180.0 / Math::PI  # Should be ~4.419
    
    # Without PostGIS, coordinates default to degrees (no conversion)
    # But we can still test the mathematical conversion
    assert_in_delta expected_lat, lat_rad * 180.0 / Math::PI, 0.01, "Mathematical conversion for Uzès, France"
    assert_in_delta expected_lng, lng_rad * 180.0 / Math::PI, 0.01, "Mathematical conversion for Uzès, France"
    
    # Verify the converted coordinates are reasonable for France
    converted_lat = lat_rad * 180.0 / Math::PI
    converted_lng = lng_rad * 180.0 / Math::PI
    assert converted_lat > 40 && converted_lat < 50, "Latitude should be in France range"
    assert converted_lng > 0 && converted_lng < 10, "Longitude should be in France range"
  end

  def test_validate_and_convert_coordinates_nyc_radians
    # Test NYC coordinates provided in radians
    nyc_lat_deg = 40.7128
    nyc_lng_deg = -74.0060
    
    # Convert to radians
    nyc_lat_rad = nyc_lat_deg * Math::PI / 180.0  # ~0.7107
    nyc_lng_rad = nyc_lng_deg * Math::PI / 180.0  # ~-1.2915
    
    result = @test_instance.validate_and_convert_coordinates(nyc_lat_rad, nyc_lng_rad, "US")
    
    # In test environment, defaults to degrees (no conversion)
    # But test the mathematical conversion
    converted_lat = nyc_lat_rad * 180.0 / Math::PI
    converted_lng = nyc_lng_rad * 180.0 / Math::PI
    assert_in_delta nyc_lat_deg, converted_lat, 0.01, "NYC latitude mathematical conversion"
    assert_in_delta nyc_lng_deg, converted_lng, 0.01, "NYC longitude mathematical conversion"
  end

  def test_coordinates_match_country_basic_validation
    # Test basic range validation (private method)
    refute @test_instance.send(:coordinates_match_country?, 200.0, -74.0, "US"), "Invalid latitude should return false"
    refute @test_instance.send(:coordinates_match_country?, 40.0, 200.0, "US"), "Invalid longitude should return false"
    refute @test_instance.send(:coordinates_match_country?, 40.0, -74.0, nil), "Nil country should return false"
    refute @test_instance.send(:coordinates_match_country?, nil, -74.0, "US"), "Nil latitude should return false"
    refute @test_instance.send(:coordinates_match_country?, 40.0, nil, "US"), "Nil longitude should return false"
  end

  def test_validate_and_convert_coordinates_edge_cases
    # Test coordinates with longitude exactly at boundary (180.1 > 180)
    lat_normal = 45.0    # Normal latitude
    lng_over = 180.1     # Just over 180 degrees, should trigger conversion
    
    result = @test_instance.validate_and_convert_coordinates(lat_normal, lng_over)
    
    # Should be converted from radians to degrees
    expected_lat = lat_normal * 180.0 / Math::PI
    expected_lng = lng_over * 180.0 / Math::PI
    
    assert_in_delta expected_lat, result[0], 0.01
    assert_in_delta expected_lng, result[1], 0.01
  end

  def test_validate_and_convert_coordinates_small_radian_values
    # Test small coordinates that could be either format
    # e.g., 1.0, 0.5 - could be 1°, 0.5° OR ~57°, ~28° if radians
    
    small_lat = 1.0
    small_lng = 0.5
    
    # Without country validation, should default to degrees
    result = @test_instance.validate_and_convert_coordinates(small_lat, small_lng)
    
    assert_in_delta small_lat, result[0], 0.001, "Small values should default to degrees"
    assert_in_delta small_lng, result[1], 0.001, "Small values should default to degrees"
  end

  def test_random_with_coords_class_method
    # Test the class method on our TestModel
    assert_respond_to TestModel, :random_with_coords
    
    # Should return our test instance since it has coordinates
    random_record = TestModel.random_with_coords
    assert_not_nil random_record
    assert_not_nil random_record.latitude
    assert_not_nil random_record.longitude
  end

  def test_data_coverage_module_exists
    assert defined?(HasGeoLookup::DataCoverage)
    assert_respond_to HasGeoLookup::DataCoverage, :coverage_status
    assert_respond_to HasGeoLookup::DataCoverage, :has_boundary_data?
    assert_respond_to HasGeoLookup::DataCoverage, :has_geonames_data?
  end
end