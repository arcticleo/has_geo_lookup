# frozen_string_literal: true

require "open-uri"
require "json"
require "rgeo"
require "fileutils"
require "digest/sha1"
require "iso_3166"

module HasGeoLookup
  class BoundaryImporter
    class << self
      # Import all available ADM levels (1-4) for a country
      #
      # @param iso2_code [String] 2-letter ISO country code (e.g., "US", "FR")
      # @param options [Hash] Import options
      # @option options [String] :cache_dir Directory for caching downloaded files
      # @option options [Boolean] :verbose Enable detailed progress output (default: true)
      #
      # @return [Hash] Import results with :success, :total_processed, :errors keys
      def import_country(iso2_code, options = {})
        iso2 = iso2_code&.upcase
        raise ArgumentError, "Please provide a 2-letter country code" unless iso2
        
        cache_dir = options[:cache_dir] || default_cache_dir
        verbose = options.fetch(:verbose, true)
        
        # Convert ISO2 to ISO3 using iso_3166 gem with fallbacks
        iso3, country_name = resolve_country_codes(iso2, verbose)
        
        errors = []
        total_processed = 0
        factory = create_geometry_factory
        
        (1..5).each do |level|
          adm = "ADM#{level}"
          puts "📍 Importing #{adm} boundaries..." if verbose
          
          result = import_adm_level(iso3, adm, factory, cache_dir, errors, verbose)
          
          unless result[:success]
            puts "⏭️  Skipping remaining ADM levels (#{adm} and higher not available)" if verbose
            break
          end
          
          total_processed += result[:count]
        end
        
        {
          success: true,
          total_processed: total_processed,
          errors: errors,
          country: { iso2: iso2, iso3: iso3, name: country_name }
        }
      end
      
      # Import boundaries for a specific ADM level
      #
      # @param iso2_code [String] 2-letter ISO country code
      # @param adm_level [String] Administrative level ("ADM1", "ADM2", "ADM3", "ADM4", "ADM5")
      # @param options [Hash] Import options (same as import_country)
      #
      # @return [Hash] Import results
      def import_level(iso2_code, adm_level, options = {})
        iso2 = iso2_code&.upcase
        raise ArgumentError, "Please provide a 2-letter country code" unless iso2
        raise ArgumentError, "Please provide ADM level (ADM1-ADM5)" unless adm_level&.match?(/\AADM[1-5]\z/)
        
        cache_dir = options[:cache_dir] || default_cache_dir
        verbose = options.fetch(:verbose, true)
        
        iso3, country_name = resolve_country_codes(iso2, verbose)
        
        errors = []
        factory = create_geometry_factory
        
        result = import_adm_level(iso3, adm_level, factory, cache_dir, errors, verbose)
        
        {
          success: result[:success],
          total_processed: result[:count],
          errors: errors,
          country: { iso2: iso2, iso3: iso3, name: country_name }
        }
      end
      
      private
      
      def default_cache_dir
        if defined?(Rails)
          Rails.root.join("db", "boundaries")
        else
          File.join(Dir.tmpdir, "has_geo_lookup_boundaries")
        end
      end
      
      def create_geometry_factory
        RGeo::Cartesian.factory(
          srid: 4326,
          uses_lenient_assertions: true,
          has_z_coordinate: false,
          wkt_parser: { support_ewkt: true }
        )
      end
      
      def resolve_country_codes(iso2, verbose = true)
        country = Iso3166.for_code(iso2)
        
        if country
          iso3 = country.code3
          country_name = country.name.downcase.split(' ').map(&:capitalize).join(' ')
          puts "🌍 Converting #{iso2} → #{iso3} (#{country_name})" if verbose
          [iso3, country_name]
        else
          # Fallback for codes not recognized by iso_3166 gem
          puts "⚠️  Country code '#{iso2}' not found in iso_3166 gem, trying direct lookup..." if verbose
          
          # Common manual mappings for missing territories
          manual_mappings = {
            'BL' => { iso3: 'BLM', name: 'Saint Barthélemy' },
            'MF' => { iso3: 'MAF', name: 'Saint Martin' },
            'SX' => { iso3: 'SXM', name: 'Sint Maarten' }
          }
          
          if manual_mappings[iso2]
            mapping = manual_mappings[iso2]
            puts "🌍 Using manual mapping: #{iso2} → #{mapping[:iso3]} (#{mapping[:name]})" if verbose
            [mapping[:iso3], mapping[:name]]
          else
            # Last resort: use ISO2 as ISO3 and try the API call
            puts "🌍 Using direct code: #{iso2} → #{iso2} (attempting API lookup)" if verbose
            [iso2, iso2]
          end
        end
      end
      
      def import_adm_level(iso3, adm_level, factory, cache_dir, errors = [], verbose = true)
        api_url = "https://www.geoboundaries.org/api/current/gbOpen/#{iso3}/#{adm_level}/"
        puts "🌍 Fetching metadata from #{api_url}..." if verbose

        # Get metadata (not cached since it's small and may change)
        begin
          metadata_response = URI.open(api_url).read
          metadata = JSON.parse(metadata_response)
        rescue OpenURI::HTTPError => e
          if e.message.include?("404")
            puts "⚠️  #{adm_level} boundaries not available for #{iso3} (404 Not Found)" if verbose
            return { success: false, count: 0 }
          else
            puts "❌ HTTP error fetching metadata: #{e.message}" if verbose
            return { success: false, count: 0 }
          end
        rescue JSON::ParserError => e
          puts "❌ Invalid JSON in API response: #{e.message}" if verbose
          return { success: false, count: 0 }
        rescue => e
          puts "❌ Unexpected error fetching metadata: #{e.class}: #{e.message}" if verbose
          return { success: false, count: 0 }
        end

        # Use simplified geometry if available, fall back to full resolution
        geojson_url = metadata["simplifiedGeometryGeoJSON"] || metadata["gjDownloadURL"]
        unless geojson_url
          puts "⚠️  No download URL found in API response for #{adm_level}" if verbose
          return { success: false, count: 0 }
        end
        
        simplified = metadata["simplifiedGeometryGeoJSON"] ? "(simplified)" : "(full resolution)"
        puts "📐 Using #{simplified} geometry" if verbose

        # Check if GeoJSON is already cached
        cached_file = local_geojson_path(iso3, adm_level, geojson_url, cache_dir)
        if File.exist?(cached_file)
          puts "📂 Using cached GeoJSON: #{cached_file}" if verbose
          begin
            data = JSON.parse(File.read(cached_file, encoding: "UTF-8"))
          rescue JSON::ParserError => e
            puts "❌ Invalid JSON in cached file, re-downloading: #{e.message}" if verbose
            File.delete(cached_file)
            data = download_and_cache_geojson(geojson_url, cached_file, verbose)
            return { success: false, count: 0 } unless data
          rescue Encoding::UndefinedConversionError => e
            puts "❌ Encoding error in cached file, re-downloading: #{e.message}" if verbose
            File.delete(cached_file)
            data = download_and_cache_geojson(geojson_url, cached_file, verbose)
            return { success: false, count: 0 } unless data
          end
        else
          data = download_and_cache_geojson(geojson_url, cached_file, verbose)
          return { success: false, count: 0 } unless data
        end

        unless data["features"] && data["features"].any?
          puts "⚠️  No boundary features found in GeoJSON for #{adm_level}" if verbose
          return { success: false, count: 0 }
        end

        count = process_features(data["features"], adm_level, geojson_url, factory, errors, verbose)
        
        puts "✅ Processed #{count} boundaries for #{adm_level}." if verbose
        { success: true, count: count }
      end
      
      def process_features(features, adm_level, geojson_url, factory, errors, verbose)
        count = 0
        
        features.each do |feature|
          props = feature["properties"]
          coords = feature["geometry"]["coordinates"]
          next unless coords && props

          name = props["shapeName"]
          shape_id = props["shapeID"]
          shape_iso = props["shapeISO"]
          shape_group = props["shapeGroup"]

          puts "🔍 Importing #{name.inspect}..." if verbose

          # Process geometry
          multi = create_multipolygon_from_feature(feature, factory, name, errors, verbose)
          next unless multi
          
          wkt = multi.as_text

          # Insert into database using the gem's Geoboundary model
          Geoboundary.connection.execute(<<~SQL)
            INSERT INTO geoboundaries (name, level, shape_id, shape_iso, shape_group, source_url, boundary, created_at, updated_at)
            VALUES (
              #{ActiveRecord::Base.connection.quote(name)},
              #{ActiveRecord::Base.connection.quote(adm_level)},
              #{ActiveRecord::Base.connection.quote(shape_id)},
              #{ActiveRecord::Base.connection.quote(shape_iso)},
              #{ActiveRecord::Base.connection.quote(shape_group)},
              #{ActiveRecord::Base.connection.quote(geojson_url)},
              ST_GeomFromText('#{wkt}', 4326),
              NOW(), NOW()
            )
            ON DUPLICATE KEY UPDATE
              name = VALUES(name),
              level = VALUES(level),
              shape_iso = VALUES(shape_iso),
              shape_group = VALUES(shape_group),
              source_url = VALUES(source_url),
              boundary = VALUES(boundary),
              updated_at = NOW()
          SQL

          count += 1
        rescue => e
          # Enhanced error info with debug context
          error_info = {
            name: name || "Unknown",
            adm_level: adm_level,
            message: "#{e.class}: #{e.message}",
            details: build_error_details(e, wkt, feature&.dig("geometry", "type"), coords&.class, coords&.size),
            backtrace: e.is_a?(NoMethodError) ? e.backtrace.first(3) : nil
          }
          errors << error_info
          puts "❌ Failed to process #{name.inspect}: #{e.class} (error details saved for summary)" if verbose
        end
        
        count
      end
      
      def create_multipolygon_from_feature(feature, factory, name, errors, verbose)
        coords = feature["geometry"]["coordinates"]
        geom_type = feature["geometry"]["type"]
        
        # Collect debug geometry structure silently
        coords_structure = "#{coords.class} -> #{coords.first&.class} -> #{coords.first&.first&.class}"
        
        polygon_groups = geom_type == "MultiPolygon" ? coords : [coords]
        debug_info = []
        
        reversed_polygons = polygon_groups.map.with_index do |poly_coords, poly_index|
          # Collect debug info silently for problematic geometries
          unless poly_coords.is_a?(Array) && poly_coords.any?
            debug_info << "poly_coords[#{poly_index}] is #{poly_coords.class}: #{poly_coords.inspect[0..200]}..."
            next nil
          end
          
          raw_ring = poly_coords.first
          unless raw_ring.is_a?(Array) && raw_ring.any?
            debug_info << "raw_ring is #{raw_ring.class}: #{raw_ring.inspect[0..200]}..."
            debug_info << "poly_coords structure: #{poly_coords.map(&:class)}"
            next nil
          end

          outer =
            if raw_ring.size == 2 && raw_ring.all? { |pt| pt.is_a?(Array) && pt.size == 2 }
              puts "⚠️  Constructing rectangular fallback for #{name.inspect} (2 points)" if verbose
              (lon1, lat1), (lon2, lat2) = raw_ring

              rectangle = [
                [lat1, lon1],
                [lat2, lon1],
                [lat2, lon2],
                [lat1, lon2],
                [lat1, lon1]
              ].map { |lat, lon| factory.point(lat, lon) }

              factory.linear_ring(rectangle)
            else
              ring_points = raw_ring.map { |lon, lat| factory.point(lat, lon) }
              factory.linear_ring(ring_points)
            end

          # Process holes with better validation
          holes = []
          if poly_coords.size > 1
            debug_info << "Processing #{poly_coords.size - 1} holes"
            holes = poly_coords[1..].filter_map.with_index do |ring, hole_index|
              unless ring.is_a?(Array) && ring.any?
                debug_info << "hole[#{hole_index}] is #{ring.class}: #{ring.inspect[0..100]}..."
                next nil
              end
              
              begin
                debug_info << "hole[#{hole_index}] has #{ring.size} points, first point: #{ring.first.inspect}"
                hole_points = ring.map { |lon, lat| factory.point(lat, lon) }
                factory.linear_ring(hole_points)
              rescue => e
                debug_info << "hole[#{hole_index}] failed: #{e.class}: #{e.message}"
                debug_info << "hole[#{hole_index}] structure: #{ring.map(&:class).uniq}"
                debug_info << "hole[#{hole_index}] sample: #{ring.first(3).inspect}"
                nil
              end
            end
            debug_info << "Successfully processed #{holes.size} holes"
          end

          begin
            # RGeo factory.polygon expects: outer_ring, hole1, hole2, hole3...
            debug_info << "Creating polygon with outer: #{outer.class}, holes: #{holes.size} (#{holes.map(&:class)})"
            factory.polygon(outer, *holes)
          rescue => e
            debug_info << "polygon creation failed: #{e.class}: #{e.message}"
            debug_info << "outer ring valid: #{outer.respond_to?(:exterior_ring)}"
            debug_info << "holes valid: #{holes.all? { |h| h.respond_to?(:exterior_ring) }}"
            # Try without holes as fallback
            begin
              debug_info << "Retrying without holes..."
              factory.polygon(outer)
            rescue => e2
              debug_info << "outer ring also failed: #{e2.class}: #{e2.message}"
              nil
            end
          end
        end.compact

        # Skip if no valid polygons were created
        if reversed_polygons.empty?
          debug_info << "No valid polygons found, skipping"
          return nil
        end

        factory.multi_polygon(reversed_polygons)
      end
      
      def local_geojson_path(iso3, adm_level, geojson_url, cache_dir)
        # Create a safe filename from the URL and parameters
        url_hash = Digest::SHA1.hexdigest(geojson_url)[0..8]
        filename = "#{iso3}-#{adm_level}-#{url_hash}.geojson"
        File.join(cache_dir, filename)
      end
      
      def build_error_details(error, wkt, geom_type, coords_class, coords_size)
        details = []
        details << "WKT length: #{wkt&.length || 'n/a'}"
        details << "Geometry type: #{geom_type || 'n/a'}"
        details << "Coordinates: #{coords_class}"
        details << "Coordinates size: #{coords_size || 'n/a'}"
        
        if error.is_a?(NoMethodError)
          details << "Method called on: #{error.receiver&.class || 'unknown'}"
        end
        
        details.join(", ")
      end
      
      def download_and_cache_geojson(geojson_url, cached_file, verbose = true)
        puts "⬇️  Downloading GeoJSON from #{geojson_url}..." if verbose
        
        begin
          geojson_response = URI.open(geojson_url, "rb") do |file|
            file.read.force_encoding("UTF-8")
          end
          data = JSON.parse(geojson_response)
          
          # Ensure directory exists
          FileUtils.mkdir_p(File.dirname(cached_file))
          
          # Cache the file
          File.write(cached_file, geojson_response, encoding: "UTF-8")
          puts "💾 Cached GeoJSON to #{cached_file}" if verbose
          
          return data
        rescue OpenURI::HTTPError => e
          puts "❌ HTTP error downloading GeoJSON: #{e.message}" if verbose
          return nil
        rescue JSON::ParserError => e
          puts "❌ Invalid JSON in GeoJSON file: #{e.message}" if verbose
          return nil
        rescue Encoding::UndefinedConversionError => e
          puts "❌ Encoding error in GeoJSON file: #{e.message}" if verbose
          return nil
        rescue => e
          puts "❌ Unexpected error downloading GeoJSON: #{e.class}: #{e.message}" if verbose
          return nil
        end
      end
    end
  end
end