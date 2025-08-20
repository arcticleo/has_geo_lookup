# frozen_string_literal: true

require "test_helper"

class IndexCheckerTest < ActiveSupport::TestCase
  test "can analyze models with HasGeoLookup" do
    # Mock a simple model class for testing
    mock_model = Class.new do
      def self.name
        "MockModel"
      end
      
      def self.table_name
        "mock_models"
      end
      
      def self.column_names
        %w[id latitude longitude city country state_or_province postal_code created_at updated_at]
      end
      
      def self.include?(module_name)
        module_name == HasGeoLookup
      end
      
      include HasGeoLookup
    end
    
    # Mock ActiveRecord connection and indexes
    connection = mock('connection')
    indexes = [
      mock('index', columns: ['latitude', 'longitude']),
      mock('index', columns: ['latitude'])
    ]
    
    ActiveRecord::Base.stubs(:connection).returns(connection)
    connection.stubs(:indexes).with('mock_models').returns(indexes)
    
    stub_const('MockModel', mock_model)
    
    analysis = HasGeoLookup::IndexChecker.check_model(mock_model)
    
    assert_equal 'mock_models', analysis[:table_name]
    assert_operator analysis[:missing_indexes], :>, 0
    assert analysis[:recommendations].any?
    assert analysis[:existing_indexes].any?
  end
  
  test "detects models that do not include HasGeoLookup" do
    mock_model = Class.new do
      def self.include?(module_name)
        false
      end
    end
    
    analysis = HasGeoLookup::IndexChecker.check_model(mock_model)
    assert analysis[:error]
  end
  
  test "generates proper index commands" do
    # Test single column index
    command = HasGeoLookup::IndexChecker.send(
      :generate_index_command, 
      'listings', 
      { columns: [:country], name: 'country' }
    )
    assert_equal "add_index :listings, :country", command
    
    # Test multi-column index
    command = HasGeoLookup::IndexChecker.send(
      :generate_index_command,
      'listings',
      { columns: [:latitude, :longitude], name: 'coordinates' }
    )
    assert_equal "add_index :listings, [:latitude, :longitude]", command
  end
  
  test "identifies missing indexes correctly" do
    existing_indexes = [
      mock('index', columns: ['latitude', 'longitude']),
      mock('index', columns: ['id'])
    ]
    
    # Should find existing index
    assert HasGeoLookup::IndexChecker.send(:has_index?, existing_indexes, [:latitude, :longitude])
    assert HasGeoLookup::IndexChecker.send(:has_index?, existing_indexes, ['latitude', 'longitude'])
    
    # Should not find missing index
    refute HasGeoLookup::IndexChecker.send(:has_index?, existing_indexes, [:country])
    refute HasGeoLookup::IndexChecker.send(:has_index?, existing_indexes, [:city, :state])
  end
  
  private
  
  def mock(name, attributes = {})
    mock_obj = Object.new
    attributes.each do |attr, value|
      mock_obj.define_singleton_method(attr) { value }
    end
    mock_obj
  end
  
  def stub_const(name, value)
    Object.const_set(name, value)
  ensure
    Object.send(:remove_const, name) if Object.const_defined?(name)
  end
end