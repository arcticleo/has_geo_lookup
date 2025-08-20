# frozen_string_literal: true

module HasGeoLookup
  # Utility class for checking and recommending database indexes for optimal performance
  #
  # This class analyzes models that include HasGeoLookup and provides recommendations
  # for database indexes to optimize geographic queries. It can detect missing indexes
  # and optionally create them automatically.
  #
  # @example Check indexes for all models
  #   HasGeoLookup::IndexChecker.analyze_all_models
  #
  # @example Check indexes for a specific model
  #   HasGeoLookup::IndexChecker.check_model(Listing)
  #
  # @example Create missing indexes
  #   HasGeoLookup::IndexChecker.create_missing_indexes(Listing)
  class IndexChecker
    class << self

    # Required columns for HasGeoLookup functionality  
    REQUIRED_COLUMNS = [
      { name: :latitude, type: :decimal, precision: 10, scale: 6 },
      { name: :longitude, type: :decimal, precision: 10, scale: 6 }
    ].freeze

    # Recommended indexes for models using HasGeoLookup functionality
    RECOMMENDED_INDEXES = {
      coordinate_indexes: [
        { columns: [:latitude, :longitude], name: 'coordinates' },
        { columns: [:latitude], name: 'latitude' },
        { columns: [:longitude], name: 'longitude' }
      ],
      geo_attribute_indexes: [
        { columns: [:country], name: 'country' },
        { columns: [:state_or_province], name: 'state_or_province' },
        { columns: [:city], name: 'city' },
        { columns: [:postal_code], name: 'postal_code' }
      ]
    }.freeze

    # Analyze all models that include HasGeoLookup
    #
    # Scans the application for models that include HasGeoLookup and analyzes
    # their index coverage for geographic operations.
    #
    # @return [Hash] Summary of analysis results by model
    #
    # @example
    #   results = HasGeoLookup::IndexChecker.analyze_all_models
    #   # => {
    #   #   "Listing" => {
    #   #     missing_indexes: 2,
    #   #     recommendations: ["add_index :listings, [:latitude, :longitude]"],
    #   #     table_name: "listings"
    #   #   }
    #   # }
    def analyze_all_models
      results = {}
      
      # Find all models that include HasGeoLookup
      models_with_geo_lookup.each do |model|
        results[model.name] = check_model(model)
      end
      
      results
    end

    # Check index coverage for a specific model
    #
    # Analyzes the database indexes for a model and compares them against
    # the recommended indexes for HasGeoLookup functionality.
    #
    # @param model [Class] ActiveRecord model class
    # @return [Hash] Analysis results with missing indexes and recommendations
    #
    # @example
    #   analysis = HasGeoLookup::IndexChecker.check_model(Listing)
    #   puts analysis[:missing_indexes].length
    #   puts analysis[:recommendations]
    def check_model(model)
      return { error: "Model does not include HasGeoLookup" } unless model.include?(HasGeoLookup)
      
      table_name = model.table_name
      existing_indexes = get_existing_indexes(table_name)
      missing_columns = check_missing_columns(model)
      missing_indexes = []
      recommendations = []
      
      # Check coordinate indexes (always recommended, but only if columns exist or will be created)
      RECOMMENDED_INDEXES[:coordinate_indexes].each do |index_def|
        # Check if all required columns exist or will be added
        columns_available = index_def[:columns].all? do |col|
          model.column_names.include?(col.to_s) || missing_columns.any? { |mc| mc[:name] == col }
        end
        
        next unless columns_available
        
        unless has_index?(existing_indexes, index_def[:columns])
          missing_indexes << index_def
          recommendations << generate_index_command(table_name, index_def)
        end
      end
      
      # Check geo attribute indexes (only for columns that exist)
      RECOMMENDED_INDEXES[:geo_attribute_indexes].each do |index_def|
        columns = index_def[:columns].select { |col| model.column_names.include?(col.to_s) }
        next if columns.empty?
        
        unless has_index?(existing_indexes, columns)
          index_def_with_existing_cols = index_def.merge(columns: columns)
          missing_indexes << index_def_with_existing_cols
          recommendations << generate_index_command(table_name, index_def_with_existing_cols)
        end
      end
      
      {
        table_name: table_name,
        missing_columns: missing_columns.length,
        missing_column_details: missing_columns,
        missing_indexes: missing_indexes.length,
        missing_index_details: missing_indexes,
        recommendations: recommendations,
        existing_indexes: existing_indexes.map { |idx| idx.columns.sort }
      }
    end

    # Check for missing required columns in a model
    #
    # @param model [Class] ActiveRecord model class
    # @return [Array<Hash>] Array of missing column definitions
    def check_missing_columns(model)
      REQUIRED_COLUMNS.reject do |col_def|
        model.column_names.include?(col_def[:name].to_s)
      end
    end


    # Generate a Rails migration file for creating missing columns and indexes
    #
    # Creates a timestamped migration file containing all missing columns and indexes for optimal
    # HasGeoLookup performance. This is the recommended approach for production use
    # as it maintains proper migration history and version control.
    #
    # @param model [Class] ActiveRecord model class, or nil for all models
    # @return [String] Path to the generated migration file, or nil if nothing needed
    #
    # @example Generate migration for a specific model
    #   HasGeoLookup::IndexChecker.generate_index_migration(Listing)
    #
    # @example Generate migration for all models with missing columns/indexes
    #   HasGeoLookup::IndexChecker.generate_index_migration
    def generate_index_migration(model = nil)
      if model
        models_to_check = { model.name => check_model(model) }
      else
        models_to_check = analyze_all_models
      end
      
      models_with_missing = models_to_check.select do |_, analysis|
        (analysis[:missing_columns] || 0) > 0 || (analysis[:missing_indexes] || 0) > 0
      end
      
      if models_with_missing.empty?
        puts "✓ All models have optimal columns and indexes for HasGeoLookup"
        return nil
      end
      
      # Generate migration content
      migration_name = "add_has_geo_lookup_setup"
      migration_name += "_for_#{model.name.underscore}" if model
      
      migration_content = generate_migration_content(models_with_missing)
      migration_path = create_migration_file(migration_name, migration_content)
      
      puts "✓ Generated migration: #{migration_path}"
      puts "Run 'rails db:migrate' to apply the columns and indexes"
      
      migration_path
    end

    # Generate a performance report for HasGeoLookup usage
    #
    # Creates a comprehensive report showing index coverage across all models
    # that use HasGeoLookup functionality.
    #
    # @return [String] Formatted report suitable for console output
    def performance_report
      results = analyze_all_models
      
      if results.empty?
        return "No models found that include HasGeoLookup"
      end
      
      report = []
      report << "=" * 80
      report << "HasGeoLookup Performance Analysis"
      report << "=" * 80
      
      total_missing = 0
      
      results.each do |model_name, analysis|
        report << "\n#{model_name} (table: #{analysis[:table_name]})"
        report << "-" * 40
        
        missing_columns = analysis[:missing_columns] || 0
        missing_indexes = analysis[:missing_indexes] || 0
        
        if missing_columns.zero? && missing_indexes.zero?
          report << "✓ All recommended columns and indexes present"
        else
          if missing_columns > 0
            total_missing += missing_columns
            report << "⚠ #{missing_columns} missing column#{'s' if missing_columns > 1}: #{analysis[:missing_column_details].map { |c| c[:name] }.join(', ')}"
          end
          
          if missing_indexes > 0
            total_missing += missing_indexes
            report << "⚠ #{missing_indexes} missing index#{'es' if missing_indexes > 1}"
            report << "\nRecommendations:"
            analysis[:recommendations].each do |rec|
              report << "  #{rec}"
            end
          end
        end
        
        report << "\nExisting indexes: #{analysis[:existing_indexes].join(', ')}" if analysis[:existing_indexes].any?
      end
      
      report << "\n" + "=" * 80
      report << "Summary: #{total_missing} missing columns/indexes across #{results.length} model#{'s' if results.length != 1}"
      
      if total_missing > 0
        report << "\nTo create missing columns and indexes, run:"
        report << "  rake has_geo_lookup:create_setup"
      end
      
      report << "=" * 80
      
      report.join("\n")
    end

    private

    # Find all models that include HasGeoLookup
    def models_with_geo_lookup
      models = []
      
      # Load all models by checking every .rb file in app/models
      Dir.glob(Rails.root.join("app/models/**/*.rb")).each do |file|
        model_name = File.basename(file, ".rb").camelize
        begin
          model = model_name.constantize
          if model.respond_to?(:include?) && model.include?(HasGeoLookup)
            models << model
          end
        rescue => e
          # Skip models that can't be loaded
          Rails.logger.debug "Skipping model #{model_name}: #{e.message}"
        end
      end
      
      models
    end

    # Get existing indexes for a table
    def get_existing_indexes(table_name)
      ActiveRecord::Base.connection.indexes(table_name)
    end

    # Check if an index exists for the given columns
    def has_index?(existing_indexes, columns)
      column_names = columns.map(&:to_s).sort
      existing_indexes.any? { |index| index.columns.sort == column_names }
    end

    # Generate Rails migration command for creating an index
    def generate_index_command(table_name, index_def)
      columns = index_def[:columns]
      if columns.length == 1
        "add_index :#{table_name}, :#{columns.first}"
      else
        "add_index :#{table_name}, #{columns.inspect}"
      end
    end

    # Generate the content for a Rails migration file
    def generate_migration_content(models_with_missing)
      migration_class_name = "AddHasGeoLookupSetup"
      
      up_commands = []
      down_commands = []
      
      models_with_missing.each do |model_name, analysis|
        table_name = analysis[:table_name]
        
        # Add missing columns first
        if analysis[:missing_column_details]&.any?
          up_commands << "    # Add missing columns for #{model_name}"
          analysis[:missing_column_details].each do |col_def|
            if col_def[:precision] && col_def[:scale]
              up_commands << "    add_column :#{table_name}, :#{col_def[:name]}, :#{col_def[:type]}, precision: #{col_def[:precision]}, scale: #{col_def[:scale]}"
            else
              up_commands << "    add_column :#{table_name}, :#{col_def[:name]}, :#{col_def[:type]}"
            end
            
            down_commands.unshift("    remove_column :#{table_name}, :#{col_def[:name]}")
          end
          up_commands << ""
        end
        
        # Add missing indexes
        if analysis[:missing_index_details]&.any?
          up_commands << "    # Add indexes for #{model_name}"
          analysis[:missing_index_details].each do |index_def|
            index_name = "index_#{table_name}_on_#{index_def[:name]}"
            columns = index_def[:columns]
            
            if columns.length == 1
              up_commands << "    add_index :#{table_name}, :#{columns.first}, name: '#{index_name}'"
            else
              up_commands << "    add_index :#{table_name}, #{columns.inspect}, name: '#{index_name}'"
            end
            
            down_commands.unshift("    remove_index :#{table_name}, name: '#{index_name}'" + 
                                  (analysis[:missing_column_details]&.any? ? " if index_exists?(:#{table_name}, name: '#{index_name}')" : ""))
          end
        end
      end
      
      <<~MIGRATION
        # frozen_string_literal: true
        
        # Migration generated by HasGeoLookup::IndexChecker
        # This migration adds required columns and recommended indexes for optimal geographic query performance
        class #{migration_class_name} < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]
          def up
        #{up_commands.join("\n")}
          end
        
          def down
        #{down_commands.join("\n")}
          end
        end
      MIGRATION
    end

    # Create a timestamped migration file
    def create_migration_file(migration_name, content)
      timestamp = Time.current.strftime("%Y%m%d%H%M%S")
      filename = "#{timestamp}_#{migration_name}.rb"
      migration_path = Rails.root.join("db", "migrate", filename)
      
      File.write(migration_path, content)
      migration_path.to_s
    end

    end # class << self
  end
end