# frozen_string_literal: true

namespace :has_geo_lookup do
  desc "Check HasGeoLookup database setup (columns and indexes)"
  task check_setup: :environment do
    puts HasGeoLookup::IndexChecker.performance_report
  end

  desc "Generate Rails migration for complete HasGeoLookup setup"
  task create_setup: :environment do
    migration_path = HasGeoLookup::IndexChecker.generate_index_migration
    
    if migration_path
      puts "\n✓ Migration generated successfully!"
      puts "Next steps:"
      puts "  1. Review the migration: #{migration_path}"
      puts "  2. Run: rails db:migrate"
    end
  end

  desc "Preview HasGeoLookup setup changes without executing (dry run)"
  task preview_setup: :environment do
    results = HasGeoLookup::IndexChecker.analyze_all_models
    
    if results.empty?
      puts "No models found that include HasGeoLookup"
      exit 0
    end
    
    models_with_missing = results.select do |_, analysis|
      (analysis[:missing_columns] || 0) > 0 || (analysis[:missing_indexes] || 0) > 0
    end
    
    if models_with_missing.empty?
      puts "✓ All models have optimal HasGeoLookup setup"
      exit 0
    end
    
    puts "Preview: HasGeoLookup setup changes that would be created"
    puts "=" * 70
    
    models_with_missing.each do |model_name, analysis|
      puts "\n#{model_name} (#{analysis[:table_name]}):"
      
      if (analysis[:missing_columns] || 0) > 0
        puts "  Missing columns:"
        analysis[:missing_column_details].each do |col_def|
          puts "    add_column :#{analysis[:table_name]}, :#{col_def[:name]}, :#{col_def[:type]}"
        end
      end
      
      if (analysis[:missing_indexes] || 0) > 0
        puts "  Missing indexes:"
        analysis[:recommendations].each do |command|
          puts "    #{command}"
        end
      end
    end
    
    puts "\n" + "=" * 70
    puts "To create this setup, run: rake has_geo_lookup:create_setup"
  end

  desc "Show detailed index analysis for a specific model"
  task :analyze_model, [:model_name] => :environment do |task, args|
    unless args[:model_name]
      puts "Usage: rake has_geo_lookup:analyze_model[ModelName]"
      puts "Example: rake has_geo_lookup:analyze_model[Listing]"
      exit 1
    end
    
    begin
      model = args[:model_name].constantize
    rescue NameError
      puts "Error: Model '#{args[:model_name]}' not found"
      exit 1
    end
    
    unless model.include?(HasGeoLookup)
      puts "Error: Model '#{args[:model_name]}' does not include HasGeoLookup"
      exit 1
    end
    
    analysis = HasGeoLookup::IndexChecker.check_model(model)
    
    puts "=" * 60
    puts "HasGeoLookup Index Analysis: #{args[:model_name]}"
    puts "=" * 60
    puts "Table: #{analysis[:table_name]}"
    puts "Missing indexes: #{analysis[:missing_indexes]}"
    
    if analysis[:existing_indexes].any?
      puts "\nExisting coordinate/geo indexes:"
      analysis[:existing_indexes].each do |columns|
        puts "  • #{columns.join(', ')}"
      end
    end
    
    if analysis[:recommendations].any?
      puts "\nRecommended additions:"
      analysis[:recommendations].each do |rec|
        puts "  #{rec}"
      end
    else
      puts "\n✓ All recommended indexes are present"
    end
    
    puts "=" * 60
  end

end