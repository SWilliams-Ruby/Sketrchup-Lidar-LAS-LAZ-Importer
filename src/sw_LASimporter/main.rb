# A Sketchup extension to import Lidar LAS files
# Usage: In Sketchup select File > Import
# select  *.las in the file type dropdown list
# click on Options to select the classification of the points to import
#
module SW
  module LASimporter
    class LASimporter < Sketchup::Importer
      include SW::LASimporter::Options
      include SW::LASimporter::ThinLas
      @@verbose = true
      
      def version()
        '1.0.0'
      end
      
      def description
        return "Lidar las Importer (*.las)"
      end
    
      def file_extension
        return "las"
      end
      
      def id
        return "SW::LASimporter"
      end
      
      def supports_options?
        return true
      end

      def do_options
        set_import_options()
      end
    
      def load_file(file_name_with_path, status)
        return if file_name_with_path.nil?
        
        begin
          model = Sketchup.active_model
          ents = model.active_entities

          model.start_operation('LAS import', true)
            grp = ents.add_group
            grp.name = 'LAS_import'      
            ents = grp.entities
            las_file = read_las_file(file_name_with_path)
            
            # las_file.dump_public_header if @verbose# debug info
            # open_choices_dialog()
            # BackGrounder.load_las_points(las_file)
            
            type, thin = get_options(las_file.num_point_records)
            unless type == :cancel # false is a Cancel
              import_las_file_points(las_file, ents, type, thin) if type
            else
              log 'Import Canceled'
            end
          model.commit_operation
          
          if grp.deleted? || ents.size == 0
            log 'No points imported'
          else
            Sketchup.active_model.active_view.zoom(grp)
          end
          
          return Sketchup::Importer::ImportSuccess

        rescue => exception
          model.abort_operation
          # User error message here
          raise exception
        end
      end

      def get_options(num_point_records)
        prompts = ["Import Type", "Thin to"]
        defaults = ["Surface", "Full Size"]
        list = ["Surface|CPoints", "Full Size|50%|20%|10%|1%|0.1%"]
        input = UI.inputbox(prompts, defaults, list, "Found #{num_point_records} points")
        return :cancel unless input
        case input[0]
        when 'Surface'
          type = :surface
        # when 'Crosses'
          # type = :crosses
        else 
          type = :cpoints
        end
        
        case input[1]
        when '0.1%'
          thin = 0.001
        when '1%'
          thin = 0.01
        when '10%'
          thin = 0.1
        when '20%'
          thin = 0.2
        when '50%'
          thin = 0.5
        else
          thin = nil
        end
        [type, thin]
      end
      
      # Populate the LASfile structure from a *.las file
      # @param file_name_with_path [String]
      # @return [LASfile]
      #
      def read_las_file(file_name_with_path)
        las_file = LASfile.new(file_name_with_path)
        log("Found #{las_file.num_point_records} point data records")
        las_file
      end
   
      # Import LAS file point records as cpoints ar as
      # a triangulated surface into the entities collection
      # @param las_file [LASfile]
      # @param ents [Sketchup::Entities]
      # @param type [String]
      #
      def import_las_file_points(las_file, ents, type, thin)
        ProgressBarBasicLASDoubleBar.new {|pbar|
          points = import_point_records(pbar, las_file, ents, type)
          return if points.size == 0
          points = thin(points, pbar, thin) if thin
          if type == :surface
            triangles = triangulate(pbar, ents, points) 
            add_surface(pbar, ents, points, triangles) 
          else
            add_points(pbar, ents, points, type)
          end
        }
      end
      
      # Import the point records that match the user's import options i.e.
      # the user's choice of which classifications to load (Ground, Water, etc.)
      # Each point will be added to the 'ents' collection as a construction point,
      # or as a triangulted surface.
      # @param las_file [LASfile], 
      # @param ents [Sketchup::Entities]
      # @param pbar [SW::ProgressBarBasic]
      # @param triangulate [Boolean]
      # @return array of points [Array]
      #
      # TODO: read the WKT/GEOTiff units from the file
      # and select the appropriate Inches per Unit
      # UNIT["US survey foot",0.3048006096012192] is 30.48 centimeters 
      # 1 Yard (International):: Imperial/US length of 3 feet or 36 inches.
      # In 1959 defined in terms of metric units as exactly   meters.
      #
      def import_point_records(pbar, las_file, ents, triangulate)
        file = las_file.file_name_with_path.split("\\").last
        points = []
        class_counts =[0] *32 # holds a running total of number of points added by classification
        num_point_records = las_file.num_point_records
        user_selected_classifications = get_import_options_classes()
        
        if import_options_horizontal_units() == "Meters"
          ipu_horiz = 39.3701 # meters to sketchup inches
        else
          ipu_horiz = 12.0 # feet to sketchup inches
        end
        
        if import_options_vertical_units() == "Meters"
          ipu_vert = 39.3701
        else
          ipu_vert = 12
        end
        
        pbar.label = "Total Progress"
        pbar.set_value(0.0)
        refresh_pbar(pbar, "Reading Point Data, Remaining points: #{num_point_records}", 0.0)
        
        # las_file.points.take(10).each_with_index{|pt, i| # debug
        las_file.points.each_with_index{|pt, i|
          ptclass = 0b01 << pt[3]
          if (user_selected_classifications & ptclass) != 0  # bitwise classifications 0 through 23
            points << [pt[0] * ipu_horiz, pt[1] * ipu_horiz, pt[2] * ipu_vert]
            class_counts[pt[3]] += 1
          end
          if pbar.update?
            refresh_pbar(pbar, "Reading Point Data, Remaining points: #{num_point_records - i}",i * 100.0 /  num_point_records)
          end
        }
        
        log "\nPoints by Classification"
        class_counts.each_with_index{|count, i| log "#{i}: #{count}"}
        log "Total points Matching Classifications #{class_counts.inject(0){|sum,x| sum + x }}"
        points
      end

      # add points to model as construction points
      #
      def add_points(pbar, ents, points, type)
        size = points.size
        pbar.label = "Total Progress"
        pbar.set_value(50.0)
        refresh_pbar(pbar, "Adding Points, Remaining points: #{size}", 0.0)
        points.each_with_index{ |pt, i|
          # if type == :cpoints
            ents.add_cpoint(pt)
          # else
            # len = 5
            # ents.add_edges([pt[0]-len,pt[1],pt[2]], [pt[0]+len,pt[1],pt[2]])
            # ents.add_edges([pt[0],pt[1]-len,pt[2]], [pt[0],pt[1]+len,pt[2]])
            # ents.add_edges([pt[0],pt[1],pt[2]-len], [pt[0],pt[1],pt[2]+len])
          # end
          if pbar.update?
            refresh_pbar(pbar, "Adding Construction Points, Remaining points: #{size - i}", \
            i * 100.0/size)
          end
        }
      end

      # triangulate points
      #
      def triangulate(pbar, ents, points)
        pbar.label = "Total Progress"
        pbar.set_value(33.0)
        refresh_pbar(pbar, "Triangulating Faces, Please wait", 0.0)
        points.uniq!
        coords = points.map { |e| [e[0], e[1]] }
        triangles = Delaunator.triangulate(coords, pbar)
        triangles
      end
      
      def add_surface(pbar, ents, points, triangles)
        # log 'adding faces'
        start = 0
        count = 2000
        total = triangles.size/3
        pbar.label = "Total Progress"
        pbar.set_value(66.0)
        refresh_pbar(pbar, "Adding Faces, Remaining faces: #{total}", 0.0)
        while start < total
          start = add_triangles(pbar, ents, points, triangles, start, count)
          start = total if start > total
          refresh_pbar(pbar, "Adding Faces, Remaining faces: #{total - start}", start * 100.0/total)
        end
      end
      
      # Add 'count' triangles to the model
      #
      def add_triangles(pbar, ents, points, triangles, start, count)
        mesh = Geom::PolygonMesh.new(points.size, count)
        points.each{ |pt| mesh.add_point(Geom::Point3d.new(*pt)) }
        (start..(start + count - 1)).each { |i|
          k = i * 3
          break if k + 3 > triangles.size
          mesh.add_polygon(triangles[k+2] + 1, triangles[k+1] + 1, triangles[k] + 1)
        }
        ents.add_faces_from_mesh(mesh)
        return start + count
      end
      
      def refresh_pbar(pbar, label, value)
        pbar.label2= label
        pbar.set_value2(value)
        pbar.refresh
      end
      
      def log(text)
        puts text if @@verbose
      end
      
    end
    Sketchup.register_importer(LASimporter.new)
  end
end


nil
