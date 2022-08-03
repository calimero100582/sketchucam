require 'sketchup.rb'
require 'sketchup.rb'
# require 'Phlatboyz/Constants.rb'

require 'Phlatboyz/PhlatboyzMethods.rb'
require 'Phlatboyz/PhlatOffset.rb'

require 'Phlatboyz/PhlatMill.rb'
require 'Phlatboyz/PhlatTool.rb'
require 'Phlatboyz/PhlatCut.rb'
require 'Phlatboyz/PSUpgrade.rb'
require 'Phlatboyz/Phlat3D.rb'
require 'Phlatboyz/PhlatProgress.rb'

module PhlatScript
   # this tool gets the list of groups containing phlatcuts and displays them in the cut order
   # it displays 2 levels deep in the case of a group of groups
   class GroupList < PhlatTool
      def initialize
         super()
         @tooltype = PB_MENU_MENU
         @tooltip = 'Group Listing in cut order'
         @statusText = 'Groups Summary display'
         @menuText = 'Groups Summary'
      end

      # recursive method to add all group names to msg
      def listgroups(msg, ent, ii, depth)
         ent.each do |bit|
            next unless bit.is_a?(Sketchup::Group)
            bname = bit.name.empty? ? 'no name' : bit.name
            spacer = '   ' * depth
            msg += spacer + ii.to_s + ' - ' + bname + "\n"
            msg = listgroups(msg, bit.entities, ii, depth + 1)
         end
         msg
      end

      def select
         groups = GroupList.listgroups
         msg = "Summary of groups in CUT ORDER\n"
         if !groups.empty?
            i = 1
            groups.each do |e|
               ename = e.name.empty? ? 'no name' : e.name
               next if ename.include?('safearea')
               msg += i.to_s + ' - ' + ename + "\n"
               msg = listgroups(msg, e.entities, i, 1) # list all the groups that are members of this group
               i += 1
            end # groups.each
         else
            msg += "No groups found to cut\n"
         end
         UI.messagebox(msg, MB_MULTILINE)
      end # select

      # copied from loopnodefromentities so if that changes maybe this should too
      def listgroups
         # copied from "loopnodefromentities" and trimmed to just return the list of groups
         model = Sketchup.active_model
         entities = model.active_entities
         safe_area_points = P.get_safe_area_point3d_array
         # find all outside loops
         loops = []
         groups = []
         phlatcuts = []
         dele_edges = [] # store edges that are part of loops to remove from phlatcuts
         entities.each do |e|
            if e.is_a?(Sketchup::Face)
               has_edges = false
               # only keep loops that contain phlatcuts
               e.outer_loop.edges.each do |edge|
                  pc = PhlatCut.from_edge(edge)
                  has_edges = (!pc.nil? && pc.in_polygon?(safe_area_points))
                  dele_edges.push(edge)
               end
               loops.push(e.outer_loop) if has_edges
            elsif e.is_a?(Sketchup::Edge)
               # make sure that all edges are marked as not processed
               pc = PhlatCut.from_edge(e)
               if pc
                  pc.processed = false
                  phlatcuts.push(pc) if pc.in_polygon?(safe_area_points) && ((pc.is_a? PhlatScript::PlungeCut) || (pc.is_a? PhlatScript::CenterLineCut))
               end
            elsif e.is_a?(Sketchup::Group)
               groups.push(e)
            end
         end # entities.each

         # make sure any edges part of a curve or loop aren't in the free standing phlatcuts array
         phlatcuts.collect! { |pc| dele_edges.include?(pc.edge) ? nil : pc }
         phlatcuts.compact!
         puts("Located #{groups.length} GROUPS containing PhlatCuts") unless groups.empty?
         groups.each do |e|
            group_name = e.name
            puts "(Group: #{group_name})" unless group_name.empty?
         end # groups.each
         loops.flatten!
         loops.uniq!
         puts("Located #{loops.length} loops containing PhlatCuts") unless loops.empty?
         groups
      end # listgroups
   end
   #-%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

   class GcodeUtil < PhlatTool
      @@x_save = nil
      @@y_save = nil
      @@cut_depth_save = nil
      @g_save_point = Geom::Point3d.new(0, 0, 0) # swarfer: after a millEdges call, this will have the last point cut

      # experimental - turn off for distribution
      @fakeorigin = false
      @optimize = true
      @group = nil

      @current_bit_diameter = 0
      @tabletop = false
      @must_ramp = false # make this an option!
      @limitangle = 0 # if > 0 will limit to this ramp angle
      @debug = true
      @debugarc = false
      @level = 0
      def initialize
         super
         @tooltype = 3
         @tooltip = PhlatScript.getString('Phlatboyz GCode')
         @largeIcon = 'images/gcode_large.png'
         @smallIcon = 'images/gcode_small.png'
         @statusText = PhlatScript.getString('Phlatboyz GCode')
         @menuText = PhlatScript.getString('GCode')
      end

      def select
         if PhlatScript.gen3D
            result = UI.messagebox 'Generate 3D GCode?', MB_OKCANCEL
            if result == 1 # OK
               GCodeGen3D.new.generate
               if PhlatScript.showGplot?
                  GPlot.new.plot
                  Sketchup.active_model.select_tool(nil) # auto select the select tool to force program show
               end
            else
               return
            end
         else
            if GcodeUtil.generate_gcode
               if PhlatScript.showGplot?
                  GPlot.new.plot
                  Sketchup.active_model.select_tool(nil) # auto select the select tool to force program show
               end
            end
         end
      end

      def statusText
         'Generate Gcode output'
      end

      def self.generate_gcode
         #      if PSUpgrader.upgrade
         #        UI.messagebox("GCode generation has been aborted due to the upgrade")
         #        return
         #      end
         Sketchup.set_status_text('Generating G-code')
         # swarfer: need these so that all aMill calls are given the right numbers, aMill should be unaware of defaults
         # by doing this we can have Z0 on the table surface, or at top of material
         @tabletop = PhlatScript.tabletop?

         if @tabletop
            @safeHeight = PhlatScript.materialThickness + PhlatScript.safeTravel.to_f
            @materialTop = PhlatScript.materialThickness
            # ZL = material thickness(MT)
            #               cut = ZL - (cutfactor * MT)
            #               safe = ZL+SH  {- safe height is safe margin above material
            @zL = PhlatScript.materialThickness
         else
            @safeHeight = PhlatScript.safeTravel.to_f
            @materialTop = 0
            @zL = 0
            # Mat Zero : ZL = 0
            #              cut = ZL - (cf * MT)
            #              safe = ZL + SH   {- safeheight is mt + some safety margin
         end
         @rampangle = PhlatScript.rampangle.to_f
         @must_ramp = PhlatScript.mustramp?

         puts(" safeheight '#{@safeHeight.to_mm}'\n")
         puts(" materialTop '#{@materialTop.to_mm}'\n")
         puts(" ZL '#{@zL.to_mm}'\n")
         puts(" tabletop '#{@tabletop}'\n")
         puts(" rampangle '#{@rampangle}'\n") if @must_ramp

         @g_save_point = Geom::Point3d.new(0, 0, 0)
         model = Sketchup.active_model
         if enter_file_dialog(model)
            # first get the material thickness from the model dictionary
            material_thickness = PhlatScript.materialThickness
            overcut = PhlatScript.cutFactor
            if overcut < 5.0
               UI.messagebox('OverCut% is less than 5%, it should be closer to 100%')
            end
            if material_thickness

               begin
                  output_directory_name = model.get_attribute Dict_name, Dict_output_directory_name, $phoptions.default_directory_name
                  output_file_name = model.get_attribute Dict_name, Dict_output_file_name, $phoptions.default_file_name
                  #            @current_bit_diameter = model.get_attribute Dict_name, Dict_bit_diameter, Default_bit_diameter
                  @current_bit_diameter = PhlatScript.bitDiameter

                  # TODO: check for existing / on the end of output_directory_name
                  absolute_File_name = output_directory_name + output_file_name

                  safe_array = P.get_safe_array
                  min_x = 0.0
                  min_y = 0.0
                  max_x = safe_array[2]
                  max_y = safe_array[3]
                  safe_area_points = P.get_safe_area_point3d_array

                  if (PhlatScript.zerooffsetx > 0) || (PhlatScript.zerooffsety > 0)
                     @fakeorigin = true
                     puts ' fakeorigin true'
                     # offset the safe area
                     min_x -= PhlatScript.zerooffsetx
                     min_y -= PhlatScript.zerooffsety
                     max_x -= PhlatScript.zerooffsetx
                     max_y -= PhlatScript.zerooffsety
                  else
                     @fakeorigin = false
                  end

                  min_max_array = [min_x, max_x, min_y, max_y, $phoptions.min_z, $phoptions.max_z]
                  # aMill = CNCMill.new(nil, nil, absolute_File_name, min_max_array)
                  aMill = PhlatMill.new(absolute_File_name, min_max_array)

                  aMill.set_bit_diam(@current_bit_diameter)
                  aMill.set_retract_depth(@safeHeight, @tabletop) # tell amill the retract height, for table zero ops

                  #   puts("starting aMill absolute_File_name="+absolute_File_name)
                  ext = if @tabletop
                           'Z ZERO IS TABLETOP'
                        else
                           '-'
                        end
                  if @fakeorigin
                     x = Sketchup.format_length(PhlatScript.zerooffsetx)
                     y =  Sketchup.format_length(PhlatScript.zerooffsety)
                     fo = "Origin offset #{x}, #{y}"
                     if ext == '-'
                        ext = fo
                     else
                        ext += "\n" + fo
                     end
                  end
                  aMill.job_start(@optimize, @debug, ext)

                  #   puts "amill jobstart done"
                  Sketchup.set_status_text('Processing loop nodes')
                  if !Sketchup.active_model.selection.empty?
                     loop_root = LoopNodeFromEntities(Sketchup.active_model.selection, aMill, material_thickness)
                  else
                     loop_root = LoopNodeFromEntities(Sketchup.active_model.active_entities, aMill, material_thickness)
                  end
                  loop_root.sort
                  millLoopNode(aMill, loop_root, material_thickness)

                  # puts("done milling")
                  if PhlatScript.UseOutfeed?
                     puts "use outfeed\n" if @debug
                     aMill.retract($phoptions.end_z,"G53 G0")
                     aMill.setZ(2*@safeHeight)
                     aMill.setComment('Outfeed')
                     aMill.move(PhlatScript.safeWidth * 0.75, 0, 2*@safeHeight,1,'G0')
                  else
                     if PhlatScript.UseEndPosition?
                        puts "use end position\n"  if @debug
                        height = if $phoptions.use_home_height?
                                    $phoptions.default_home_height
                                 else
                                    @safeHeight
                                 end
                        aMill.retract(@safeHeight) # forces cmd_rapid
                        aMill.setComment('EndPosition')
                        aMill.move(PhlatScript.end_x, PhlatScript.end_y, height, PhlatScript.feedRate, 'G0')
                     else
                        # retracts the milling head and and then moves it home.
                        if $phoptions.use_home_height?
                           aMill.setComment("home height")
                           aMill.retract($phoptions.default_home_height)
                        else
                           aMill.retract(@safeHeight) 
                           aMill.setZ(@safeHeight * 2) #tell home to use G53
                        end
                     
                        # This prevents accidental milling
                        # through your work piece when moving home.
                        aMill.home
                     end
                  end
                  if PhlatScript.useOverheadGantry?
                     if $phoptions.use_home_height?
                        aMill.retract($phoptions.default_home_height)
                     end
                  end
                  if (!$phoptions.use_home_height?) && (!PhlatScript.UseEndPosition?) && (!PhlatScript.UseOutfeed?)
                     if aMill.notequal(aMill.getZ, 2* @safeHeight)
                        if !PhlatScript.useLaser?
                           aMill.retract($phoptions.end_z,"G53 G0")
                           aMill.setZ(2*@safeHeight)
                           aMill.setCmd('G0')
                        end   
                     end
                  end

                  # puts("finishing up")
                  Sketchup.set_status_text('Job finish')
                  aMill.job_finish # output housekeeping code
                  return true
               rescue
                  puts $ERROR_INFO
                  UI.messagebox 'GcodeUtil.generate_gcode FAILED; Error:' + $ERROR_INFO.to_s
                  return false
               end
            else
               UI.messagebox(PhlatScript.getString('You must define the material thickness.'))
               return false
            end
         else
            return false
         end
      end

      # #PLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMAPLASMA
      ## generate gcode for a plasma cutter
      ## no Z movement
      ## allow for user specified codes prior to G0 and G1 moves, whenever it changes from G0 to G1 and back
      def generate_gcode_plasma
         #      if PSUpgrader.upgrade
         #        UI.messagebox("GCode generation has been aborted due to the upgrade")
         #        return
         #      end

         # swarfer: need these so that all aMill calls are given the right numbers, aMill should be unaware of defaults
         # by doing this we can have Z0 on the table surface, or at top of material
         @tabletop = PhlatScript.tabletop?

         if @tabletop
            @safeHeight = PhlatScript.materialThickness + PhlatScript.safeTravel.to_f
            @materialTop = PhlatScript.materialThickness
            # ZL = material thickness(MT)
            #               cut = ZL - (cutfactor * MT)
            #               safe = ZL+SH  {- safe height is safe margin above material
            @zL = PhlatScript.materialThickness
         else
            @safeHeight = PhlatScript.safeTravel.to_f
            @materialTop = 0
            @zL = 0
            # Mat Zero : ZL = 0
            #              cut = ZL - (cf * MT)
            #              safe = ZL + SH   {- safeheight is mt + some safety margin
         end
         @rampangle = PhlatScript.rampangle.to_f
         @must_ramp = PhlatScript.mustramp?

         puts(" safeheight '#{@safeHeight.to_mm}'\n")
         puts(" materialTop '#{@materialTop.to_mm}'\n")
         puts(" ZL '#{@zL.to_mm}'\n")
         puts(" tabletop '#{@tabletop}'\n")
         puts(" rampangle '#{@rampangle}'\n") if @must_ramp

         @g_save_point = Geom::Point3d.new(0, 0, 0)
         model = Sketchup.active_model
         if enter_file_dialog(model)
            # first get the material thickness from the model dictionary
            material_thickness = PhlatScript.materialThickness
            if material_thickness

               begin
                  output_directory_name = model.get_attribute Dict_name, Dict_output_directory_name, $phoptions.default_directory_name
                  output_file_name = model.get_attribute Dict_name, Dict_output_file_name, $phoptions.default_file_name
                  #            @current_bit_diameter = model.get_attribute Dict_name, Dict_bit_diameter, Default_bit_diameter
                  @current_bit_diameter = PhlatScript.bitDiameter

                  # TODO: check for existing / on the end of output_directory_name
                  absolute_File_name = output_directory_name + output_file_name

                  safe_array = P.get_safe_array
                  min_x = 0.0
                  min_y = 0.0
                  max_x = safe_array[2]
                  max_y = safe_array[3]
                  safe_area_points = P.get_safe_area_point3d_array

                  min_max_array = [min_x, max_x, min_y, max_y, $phoptions.min_z, $phoptions.max_z]
                  # aMill = CNCMill.new(nil, nil, absolute_File_name, min_max_array)
                  aMill = PhlatMill.new(absolute_File_name, min_max_array)

                  aMill.set_bit_diam(@current_bit_diameter)
                  aMill.set_retract_depth(@safeHeight, @tabletop) # tell amill the retract height, for table zero ops

                  #   puts("starting aMill absolute_File_name="+absolute_File_name)
                  ext = if @tabletop
                           'Z ZERO IS TABLETOP'
                        else
                           '-'
                        end
                  aMill.job_start(@optimize, @debug, ext)
                  #   puts "amill jobstart done"
                  loop_root = LoopNodeFromEntities(Sketchup.active_model.active_entities, aMill, material_thickness)
                  loop_root.sort
                  millLoopNode(aMill, loop_root, material_thickness)

                  # puts("done milling")
                  if PhlatScript.UseOutfeed?
                     aMill.retract(@safeHeight)
                     aMill.cncPrintC('Outfeed')
                     aMill.move(PhlatScript.safeWidth * 0.75, 0)
                  else
                     if PhlatScript.UseEndPosition?
                        height = if $phoptions.use_home_height?
                                    $phoptions.default_home_height
                                 else
                                    @safeHeight
                                 end
                        aMill.retract(@safeHeight) # forces cmd_rapid
                        aMill.cncPrintC('EndPosition')
                        aMill.move(PhlatScript.end_x, PhlatScript.end_y, height, 100, 'G0')
                     else
                        # retracts the milling head and and then moves it home.
                        # This prevents accidental milling
                        # through your work piece when moving home.
                        aMill.home
                     end
                  end
                  if PhlatScript.useOverheadGantry?
                     #              if ($phoptions.use_home_height? != nil)
                     if $phoptions.use_home_height?
                        aMill.retract($phoptions.default_home_height)
                     end
                  #              end
                  end

                  # puts("finishing up")
                  aMill.job_finish # output housekeeping code
               rescue
                  UI.messagebox 'GcodeUtil.generate_gcode failed; Error:' + $ERROR_INFO
               end
            else
               UI.messagebox(PhlatScript.getString('You must define the material thickness.'))
            end
         end
      end

      private
		
		# set feed_adjust false if doing an outside cut and arc is on outside
		# returns old value of feed_adjust
		def self.dofeedadjust(cutkind, g3)
			# v1.5 - only feedadjust on outside arcs if they are inside a shape
			fawas = $phoptions.feed_adjust?
			if ($phoptions.feed_adjust?) && (cutkind == PhlatScript::OutsideCut)
				if PhlatScript.useOverheadGantry? == g3
					$phoptions.feed_adjust = false
				end
			end
			if ($phoptions.feed_adjust?) && (cutkind == PhlatScript::InsideCut)
				if PhlatScript.useOverheadGantry? == g3
					$phoptions.feed_adjust = false
				end
			end
			fawas
		end

      def self.LoopNodeFromEntities(entities, aMill, material_thickness)
         #      puts"loopnodefromentities #{entities.length}"
         model = Sketchup.active_model
         safe_area_points = P.get_safe_area_point3d_array
         # find all outside loops
         loops = []
         groups = []
         phlatcuts = []
         dele_edges = [] # store edges that are part of loops to remove from phlatcuts
         entities.each do |e|
            if e.is_a?(Sketchup::Face)
               has_edges = false
               # only keep loops that contain phlatcuts
               e.outer_loop.edges.each do |edge|
                  pc = PhlatCut.from_edge(edge)
                  has_edges = (!pc.nil? && pc.in_polygon?(safe_area_points))
                  dele_edges.push(edge)
               end
               loops.push(e.outer_loop) if has_edges
            elsif e.is_a?(Sketchup::Edge)
               # make sure that all edges are marked as not processed
               pc = PhlatCut.from_edge(e)
               if pc
                  pc.processed = false
                  phlatcuts.push(pc) if pc.in_polygon?(safe_area_points) && ((pc.is_a? PhlatScript::PlungeCut) || (pc.is_a? PhlatScript::CenterLineCut))
               end
            elsif e.is_a?(Sketchup::Group)
               groups.push(e) # should only do this if it is inside safearea
            end
         end

         # make sure any edges part of a curve or loop aren't in the free standing phlatcuts array
         phlatcuts.collect! { |pc| dele_edges.include?(pc.edge) ? nil : pc }
         phlatcuts.compact!
         puts("Located #{groups.length} GROUPS containing PhlatCuts") unless groups.empty?
         groups.each do |e|
            # this is a bit hacky and we should try to use a transformation based on
            # the group.local_bounds.corner(0) in the future
            group_name = e.name
            if !group_name.empty? # the safe area labels are groups with names containing 'safearea', dont print them
               @group = group_name
               aMill.cncPrintC("Group: #{group_name}") unless group_name.include?('safearea')
               puts PhlatScript.gcomment("Group: #{group_name}") unless group_name.include?('safearea')
            else
               @group = nil
            end
            model.start_operation 'Exploding Group', true
            es = e.explode
            gnode = LoopNodeFromEntities(es, aMill, material_thickness)
            gnode.sort
            #		  puts "GNODE #{gnode}"
            millLoopNode(aMill, gnode, material_thickness)
            # abort the group explode
            model.abort_operation
            next if group_name.empty?
            @group = nil
            aMill.cncPrintC("Group complete: #{group_name}") unless group_name.include?('safearea')
            puts PhlatScript.gcomment("Group end: #{group_name}") unless group_name.include?('safearea')
         end
         loops.flatten!
         loops.uniq!
         puts("Located #{loops.length} loops containing PhlatCuts") unless loops.empty?

         loop_root = LoopNode.new(nil)
         loops.each do |loop|
            loop_root.find_container(loop)
         end

         # push all the plunge, centerline and fold cuts into the proper loop node
         phlatcuts.each do |pc|
            loop_root.find_container(pc)
            pc.processed = true
         end
         loop_root
      end

      # take array of loop node sorted cuts and return true if they are all the same type of cut
      def self.sameType(edges)
         first = true
         same = false
         atype = ''
         edges.each do |sc| # find out if all same type of cuts
            #		   puts "sc #{sc}"
            if first
               atype = sc.class.to_s
               #            puts "atype=#{atype}"
               first = false
               same = true
            else
               if atype != sc.class.to_s
                  same = false
                  break
                end
            end
         end
         if same
            return atype
         else
            return nil
         end
      end

      # compare two cuts and return true if they share a vertex
      def self.shareaVertex(v1, v2)
         c1 = ((v1.edge.start.position.x - v2.edge.start.position.x).abs < 0.001) &&
              ((v1.edge.start.position.y - v2.edge.start.position.y).abs < 0.001)

         c2 = ((v1.edge.start.position.x - v2.edge.end.position.x).abs < 0.001) &&
              ((v1.edge.start.position.y - v2.edge.end.position.y).abs < 0.001)

         c3 = ((v1.edge.end.position.x - v2.edge.start.position.x).abs < 0.001) &&
              ((v1.edge.end.position.y - v2.edge.start.position.y).abs < 0.001)

         c4 = ((v1.edge.end.position.x - v2.edge.end.position.x).abs < 0.001) &&
              ((v1.edge.end.position.y - v2.edge.end.position.y).abs < 0.001)
         c1 || c2 || c3 || c4
      end

      # take the array of edges of *same* type and cut the connected ones together
      # probably only useful for centerline and fold cuts
      # for centerlines, must check cut_reversed? for each cut
      def self.cutConnected(aMill, sortedcuts, material_thickness)
         # create an array of all connected cuts and cut them, until no more cuts found
         # done: there is something wrong with this, on multipass it stuffs up the cut order for centerlines, sometimes
         # needed to check cut_reversed?
         debugcutc = false
         centers = []
         cnt = 1
         prev = nil
         pkrev = prrev = rev = false
         puts "cutc: cutting #{sortedcuts.size} edges" if debugcutc
         sortedcuts.each do |pk|
            #               puts "looking at #{pk} #{cnt}"
            pkrev ||= pk.cut_reversed?
            if cnt == 1
               prev = pk
               # puts "pushing first #{pk} #{prev} #{cnt}"
               centers.push(pk)
               prrev = rev = pk.cut_reversed?
               puts "start #{cnt} #{pk.edge.start.position} #{pk.edge.end.position} #{pk.cut_reversed?}" if debugcutc
            else
               # if prev is connected to pk then add pk to array
               #            puts "#{cnt} #{pk.edge.start.position} #{pk.edge.end.position}"
               # puts "cnt #{cnt} #{pk}"
               puts 'cutc: prev is nil' if prev.nil?
               puts 'cutc: pk is nil' if pk.nil?
               if shareaVertex(prev, pk)
                  puts "shared pushing #{pk.edge.start.position} #{pk.edge.end.position} #{pk.cut_reversed?} #{cnt}" if debugcutc

                  # try to figure cut direction for this segment
                  if prev.cut_reversed?
                     if prev.edge.start.position == pk.edge.start.position
                        pk.cut_reversed = false
                     end
                     if prev.edge.start.position == pk.edge.end.position
                        pk.cut_reversed = true
                     end
                  else
                     if prev.edge.end.position == pk.edge.end.position
                        pk.cut_reversed = true
                     end
                     if prev.edge.end.position == pk.edge.start.position
                        pk.cut_reversed = false
                     end
                  end

                  centers.push(pk)
                  # TODO: if rev changes after 2nd push, cut what you got and start again?
                  prrev = rev

                  rev = (((pk.edge.end.position.x - prev.edge.start.position.x).abs < 0.001) && ((pk.edge.end.position.y - prev.edge.start.position.y).abs < 0.001))
                  if prrev != rev
                     puts "cutc: rev changed to #{rev} at #{cnt} #{centers.size}" if debugcutc
                  end
               else
                  unless centers.empty?
                     puts "cutc: CUTTING connected centers #{rev} #{centers.size}" if debugcutc
                     #                        centers.reverse! if rev
                     if rev && !pkrev
                        puts 'cuts: reversing array' if debugcutc
                        centers.reverse!
                        rev = false
                     end
                     unless millEdges(aMill, centers, material_thickness, rev)
                        raise 'milledges failed'
                     end
                     prrev = rev = false
                  end
                  centers = []
                  centers.push(pk)
                  prrev = rev = pk.cut_reversed?
                  puts "restart #{cnt} #{pk.edge.start.position} #{pk.edge.end.position} #{pk.cut_reversed?}" if debugcutc
               end
               prev = pk
            end
            cnt += 1
         end
         unless centers.empty?
            puts "cutc: remaining Centerlines  rev(#{rev}) pkrev(#{pkrev})  centers.size(#{centers.size})" if debugcutc
            if rev && !pkrev
               #                     puts " cutting remaining centers with rev TRUE"
               #                     c = 1
               #                     centers.each { |ed|
               #                        puts " #{c} #{ed.edge.start.position} #{ed.edge.end.position}"
               #                        }
               puts 'cuts: reversing array' if debugcutc
               centers.reverse!
               rev = false
            end
            unless millEdges(aMill, centers, material_thickness, rev)
               raise 'milledges failed'
            end
         end
      end

      def self.millLoopNode(aMill, loopNode, material_thickness)
         debugmln = false
         @level += 1
         caller_line = caller.first.split('/')[7]
         puts "millLoopNode #{@level} #{caller_line}" if debugmln

         # always mill the child loops first
         loopNode.children.each do |childloop|
            puts "mln#{@level}: mill child loop" if debugmln
            millLoopNode(aMill, childloop, material_thickness)
         end
         #      if (PhlatScript.useMultipass?) and (Use_old_multipass == false)
         #        loopNode.sorted_cuts.each { |sc| millEdges(aMill, [sc], material_thickness) }
         #      else
         #       millEdges(aMill, [sc], material_thickness)
         #      end

         if PhlatScript.useMultipass? # and (Use_old_multipass == false)
            # are all the cuts the same type?
            same = sameType(loopNode.sorted_cuts) # return type name if same, else nil
            if same # all same type, if they are connected, cut together, else seperately
               atype = same
               puts "SAME #{atype}" if debugmln
               if (atype == 'PhlatScript::CenterLineCut') || (atype == 'PhlatScript::FoldCut')
                  # TODO: fix cutConnected
                  puts 'cutConnected' if debugmln
                  cutConnected(aMill, loopNode.sorted_cuts, material_thickness)
               else
                  puts "  same together #{atype}" if debugmln
                  unless millEdges(aMill, loopNode.sorted_cuts, material_thickness)
                     raise 'milledges failed'
                  end
               end
            else
               #   create arrays of same types, and cut them together
               folds = []
               centers = []
               others = [] # mostly plunge cuts
               loopNode.sorted_cuts.each do |sc|
                  cls = sc.class
                  case cls.to_s
                  when 'PhlatScript::FoldCut'
                     folds.push(sc)
                  when 'PhlatScript::CenterLineCut'
                     centers.push(sc)
                  else
                     ##					  puts "   You gave me #{cls}."
                     others.push(sc)
                  end
               end
               unless folds.empty?
                  puts "   all folds #{folds.length}" if debugmln
                  cutConnected(aMill, folds, material_thickness)
                  # millEdges(aMill,folds, material_thickness)
                  # folds.each { |sc| millEdges(aMill, [sc], material_thickness) }
               end
               unless centers.empty?
                  puts "mln#{@level}: all CenterLines #{centers.length}" if debugmln
                  cutConnected(aMill, centers, material_thickness)
                  # millEdges(aMill,centers, material_thickness)
               end
               unless others.empty?
                  #				puts "   all others #{others.length}"
                  unless millEdges(aMill, others, material_thickness)
                     raise 'milledges failed'
                  end
               end
            end
         else ## if not multipass, just cut em
            puts "mln#{@level}: JUST CUT EM, NOTMULTI #{loopNode.sorted_cuts.length}" if debugmln
            unless millEdges(aMill, loopNode.sorted_cuts, material_thickness)
               raise 'milledges failed'
            end
         end

         #      end

         # finally we can walk the loop and make it's cuts
         puts "mln#{@level}: finally walk edges" if debugmln
         edges = []
         reverse = false
         pe = nil
         unless loopNode.loop.nil?
            loopNode.loop.edgeuses.each do |eu|
               pe = PhlatCut.from_edge(eu.edge)
               next unless pe && !pe.processed
               #           if (!Sketchup.active_model.get_attribute(Dict_name, Dict_overhead_gantry, $phoptions.default_overhead_gantry?))
               if !PhlatScript.useOverheadGantry?
                  reverse = reverse || pe.is_a?(PhlatScript::InsideCut) || pe.is_a?(PhlatScript::PocketCut) || eu.reversed?
               else
                  reverse = reverse || pe.is_a?(PhlatScript::OutsideCut) || eu.reversed?
               end
               edges.push(pe)
               pe.processed = true
            end
            loopNode.loop_start.downto(0) do |x|
               edges.push(edges.shift) if x > 0
            end
            edges.reverse! if reverse
         end
         edges.compact!
         unless edges.empty?
            puts "mln#{@level}:  finally milledges #{edges.size} reverse #{reverse}" if debugmln
            unless millEdges(aMill, edges, material_thickness, reverse)
               raise 'MillEdges failed'
            end
         end

         puts "   millLoopNode exit #{@level}" if debugmln
         @level -= 1
       end

      def self.optimize(edges, reverse, trans, aMill)
         unless @g_save_point.nil?
            # puts "optimize: last point  #{@g_save_point}"
            # swarfer: find closest point -that is not a tabcut- and re-order edges to start there
            cnt = edges.size
            idx = 0
            mindist = 100_000
            idxsave = -1
            if edges.length > 1
               if edges[0].is_a? PhlatScript::CenterLineCut
                  # if the first 2 segments would be backtacked, force the first segment to reverse
                  # the backtack code then fixes the rest of the segments
                  if edges[0].edge.start.position == edges[1].edge.end.position
                     if edges[0].cut_reversed?.nil?
                        edges[0].cut_reversed = true
                     else
                        edges[0].cut_reversed = !edges[0].cut_reversed
                     end
                  end
                  return edges
               end
            end
           #       attempts at optmizing centerlines....
           #     puts "before"
           #          if ((cnt > 1) && (edges[0].kind_of? PhlatScript::CenterLineCut))
           #             if (reverse)
           #                puts "reverse true in centerline optimize"
           #             else
           #                puts "cnt #{cnt}"
           #                edges.each { | phlatcut |
           #                   a = phlatcut.edge.start.position
           #                   b = phlatcut.edge.end.position
           #                   puts "a #{a}   b #{b}  #{reverse} "
           #
           #                   point = (trans ? (a.transform(trans)) : a)
           #                   adist = point.distance(@g_save_point)
           #                   point = (trans ? (b.transform(trans)) : b)
           #                   bdist = point.distance(@g_save_point)
           #
           #                   puts "   #{adist}   #{bdist}"
           #                   }
           #               # a = edges[0].edge.start.position
           #               # b = edges[cnt-1].edge.end.position
           #               # puts "a #{a}   b #{b}  #{reverse}"
           #
           #               # point = (trans ? (a.transform(trans)) : a)
           #               # adist = point.distance(@g_save_point)
           #               # point = (trans ? (b.transform(trans)) : b)
           #               # bdist = point.distance(@g_save_point)
           #
           #               # puts "#{adist}   #{bdist}"
           #             end
           #             if (cnt == 1)
           #                a = edges[0].edge.start.position
           #                b = edges[0].edge.end.position
           #                puts "a #{a}   b #{b}  #{reverse}"
           #
           #                point = (trans ? (a.transform(trans)) : a)
           #                adist = point.distance(@g_save_point)
           #                point = (trans ? (b.transform(trans)) : b)
           #                bdist = point.distance(@g_save_point)
           #
           #                puts "#{adist}   #{bdist}"
            #                puts "edge #{edges[0]}"
            #                if (reverse)   # then b is start point
            #                   if (bdist > adist)   # then we need to reverse this edge so it starts at b
            #  #                     c = edges[0].edge.start
            #  #                     edges[0].edge.start = edges[0].edge.end
            #  #                     edges[0].edge.end = c
            #                   end
            #                else   #a is start point
            #                   if (adist > bdist)   # then we need to reverse this edge so it starts at b
            #  #                     c = edges[0].edge.start
            #  #                     edges[0].edge.start = edges[0].edge.end
            #  #                     edges[0].edge.end = c
            #                   end
            #                end
            #
            #             end
            #
            #             return edges
            #  #               if (phlatcut.kind_of? PhlatScript::CenterLineCut)
            #  #                  #only look at first and last point
            #  #                  if idx == 0
            #  #		     puts "optimize centerline first point"
            #  #                     point = (trans ? (cp.transform(trans)) : cp)
            #  #                     dist = point.distance(@g_save_point)
            #  #                  end
            #  #                  if idx == (edges.size-1)
            #  #		     puts "last point"
            #  #                  end
            #          end
            #     puts "after"
            edges.each do |phlatcut|
               #            if phlatcut.kind_of?( PhlatScript::CenterLineCut)
               # find which end is closest
               # puts "centerline #{phlatcut}"
               #            end
               #               puts "edge #{phlatcut}"
               phlatcut.cut_points(reverse) do |cp, _cut_factor|
                  if (!phlatcut.is_a? PhlatScript::TabCut) && (!phlatcut.is_a? PhlatScript::PocketCut)
                     #                     puts "   cutpoint #{cp} #{cut_factor}"
                     # if ramping then ignore segments that are too short
                     if @must_ramp
                        if phlatcut.edge.length < aMill.tooshorttoramp
                           puts "#{phlatcut.edge.length.to_mm} < #{aMill.tooshorttoramp.to_mm}" if @debug
                           break
                        end
                     end

                     # transform the point if a transformation is provided
                     point = (trans ? cp.transform(trans) : cp)
                     dist = point.distance(@g_save_point)
                     if dist < mindist
                        @whichend = idxsave == idx
                        mindist = dist
                        idxsave = idx
                        #                    puts "  saved #{idx} at #{dist} distance #{point} #{@whichend}"
                     end
                     break # only look at the first cut point
                  else
                     break
                  end # if not tabcut
               end # cut_points
               idx += 1
            end # edges.each

            return edges if idxsave == -1 # this means that no optimized edge was found, often happens with inside cuts on circles with ramping on, the segments are too short

            # puts "reStart from #{idxsave} of #{cnt} mindist #{mindist}"
            # puts "reverse #{reverse}"
            prev = (idxsave - 1 + cnt) % cnt
            nxt = (idxsave + 1 + cnt) % cnt
            # puts edges[prev] , edges[idxsave] , edges[nxt]

            if edges[idxsave].is_a? PhlatScript::PlungeCut
               idxsave = 0 # ignore plunge cuts - todo: maybe we can sort them?
               changed = true
            else
               changed = false
               if edges[idxsave].is_a? PhlatScript::CenterLineCut
                  # puts "ignoring centerlinecut"
                  changed = true
                  idxsave = 0
               end
               #              puts "ignoring tab cuts for the moment, just use the nearest point"

               #              if (edges[idxsave].kind_of? PhlatScript::InsideCut)
               #                if (!@whichend )
               #                  idxsave = (idxsave - 1 + cnt) % cnt
               #                  puts "   idxsave moved -1 to #{idxsave} whichend false"
               #                  changed = true
               #                end
               #              end

               if (edges[idxsave].is_a? PhlatScript::OutsideCut) && reverse && @whichend
                  idxsave = (idxsave + 1 + cnt) % cnt
                  #                  puts "   idxsave moved +1 to #{idxsave} whichend true reverse=true"
                  changed = true
               end

               # idxsave 2 reverse=false whichend=true kind_of=Insidecut   +1
               if (edges[idxsave].is_a? PhlatScript::InsideCut) && !reverse && @whichend
                  idxsave = (idxsave + 1 + cnt) % cnt
                  #                  puts "   idxsave moved +1 to #{idxsave} whichend true reverse=false"
                  changed = true
               end

               #              if (edges[prev].kind_of? PhlatScript::TabCut) &&
               #                 (edges[idxsave].kind_of? PhlatScript::OutsideCut) &&
               #                 (edges[nxt].kind_of? PhlatScript::OutsideCut)
               #                idxsave = (idxsave + 1 + cnt) % cnt
               #                puts "   idxsave moved +1 to #{idxsave} away from outside tab TOO"
               #                changed = true
               #              end

               #             if (edges[prev].kind_of? PhlatScript::TabCut) &&
               #                (edges[idxsave].kind_of? PhlatScript::InsideCut) &&
               #                (edges[nxt].kind_of? PhlatScript::InsideCut)
               #               idxsave = (idxsave + 1 + cnt) % cnt
               #               #puts "   idxsave moved to #{idxsave} away from inside tab"
               #               changed = true
               #             end

               #              if (edges[prev].kind_of? PhlatScript::InsideCut) &&
               #                 (edges[idxsave].kind_of? PhlatScript::InsideCut) &&
               #                 (edges[nxt].kind_of? PhlatScript::TabCut)
               #                idxsave = (idxsave - 1 + cnt) % cnt
               #                #puts "   idxsave moved to #{idxsave} away from inside tab"
               #                changed = true
               #              end

               #             if (edges[prev].kind_of? PhlatScript::OutsideCut) &&
               #                (edges[idxsave].kind_of? PhlatScript::OutsideCut) &&
               #                (edges[nxt].kind_of? PhlatScript::TabCut)
               #               idxsave = (idxsave - 1 + cnt) % cnt
               #               puts "   idxsave moved -1 to #{idxsave} away from outside tab OOT"
               #               changed = true
               #             end

               #              if (edges[prev].kind_of? PhlatScript::OutsideCut) &&
               #                 (edges[idxsave].kind_of? PhlatScript::OutsideCut) &&
               #                 (edges[nxt].kind_of? PhlatScript::OutsideCut)
               #                idxsave = (idxsave + 1 + cnt) % cnt
               #                puts "   idxsave moved +1 #{idxsave} OOO"
               #                changed = true
               #              end

               #              if (edges[prev].kind_of? PhlatScript::InsideCut) &&
               #                 (edges[idxsave].kind_of? PhlatScript::InsideCut) &&
               #                 (edges[nxt].kind_of? PhlatScript::InsideCut)
               #                idxsave = (idxsave - 1 + cnt) % cnt
               #                puts "   idxsave moved -1 #{idxsave} III"
               #                changed = true
               #              end

               #              if !changed
               #                 if reverse
               #                   idxsave = (idxsave + 1 + cnt) % cnt
               #                   puts "   idxsave moved to #{idxsave} reverse=true"
               #                 else
               #                   idxsave = (idxsave + 1 + cnt) % cnt
               #                   puts "   idxsave moved to #{idxsave} reverse=false"
               #                 end
               #              end
            end # else is not plungecut

            ctype = 'other'
            ctype = 'Insidecut' if edges[idxsave].is_a? PhlatScript::InsideCut
            ctype = 'Outsidecut' if edges[idxsave].is_a? PhlatScript::OutsideCut

            # puts "  idxsave #{idxsave} reverse=#{reverse} whichend=#{@whichend} kind_of=#{ctype}"
            # idxsave = 0
            if idxsave > 0
               newedges = []
               done = false
               idx = idxsave # start here
               puts "moving #{ctype} to idxsave #{idxsave} #{ctype}"
               until done
                  newedges.push(edges[idx])
                  #               puts "   pushed #{idx} #{edges[idx]}"
                  idx += 1
                  idx = 0 if idx == cnt
                  done = true if idx == idxsave
               end # while
               edges = newedges
            end

         end # if g_save_point
         edges
      end

      # lengthen the edge by 'short'
      def self.lengthen(ledge, short)
         pts = []
         cf = 0
         puts "#{ledge.edge.start.position}\n"
         puts "#{ledge.edge.end.position}\n"
         s = ledge.edge.start.position
         e = ledge.edge.end.position
         if s.x == e.x
            puts "adding to x\n"
            ledge.edge.end.position.x += short
         elsif s.y == e.y
            puts "adding to Y\n"
            ledge.edge.end.position.y += short
         else
            theta = Math.asin((e.y - s.y) / (e.x - s.x))
            puts "theta #{theta}\n"
            ax = Math.cos(theta) * short
            puts "  ax #{ax.to_mm}\n"
            ay = Math.sin(theta) * short
            puts "  ay #{ay.to_mm}\n"
            ledge.edge.end.position.x = ledge.edge.end.position.x + ax
            ledge.edge.end.position.y += ay
         end

         puts "  #{ledge.edge.end.position}\n"

         ledge
      end

      # modify the list of edges to make the dragknife turn corners properly
      def dragknife(edges, reverse, _trans)
         anglelimit = 20 # ignore less than this
         drag = 2.mm # distance from axle to knife tip
         newedges = edges
         pts = []
         edges.each do |phlatcut|
            puts "#{phlatcut}\n"
            phlatcut.cut_points(reverse) do |cp, _cut_factor|
               # puts "   #{cp}\n";
               #         point = (trans ? (cp.transform(trans)) : cp)
               point = cp
               pts.push(point)
               break # only first points
            end
         end
         i = pts.length - 1
         while i > 0 # skip first point, go backwards through edges
            prev = pts[i - 1]
            nex = if i == (pts.length - 1)
                     pts[0]
                  else
                     pts[i + 1]
                  end
            # find angle between them http://stackoverflow.com/questions/21686913/collapse-consecutive-same-elements-in-array/21693144#21693144
            p0p1 = (pts[i].x - prev.x)**2 + (pts[i].y - prev.y)**2
            p2p1 = (pts[i].x - nex.x)**2 + (pts[i].y - nex.y)**2
            p0p2 = (nex.x - prev.x)**2 + (nex.y - prev.y)**2
            angle = Math.acos((p2p1 + p0p1 - p0p2) / Math.sqrt(4 * p2p1 * p0p1)) * 180 / Math::PI
            puts "#{i}   angle #{angle}\n"
            if angle > anglelimit # then need to insert corner
               # lengthen prev-i by drag
               newedges[i - 1] = lengthen(newedges[i - 1], drag)
               puts " new #{newedges[i - 1]}\n"
               # shorten i-nex by drag
               # insert arc centered on i, begin end prev-i, end begin nex
            end
            i -= 1
         end

         edges
      end

      def self.millEdges(aMill, edges, material_thickness, reverse = false)
         caller_line = caller.first
         #puts "millEdges : #{caller_line}"         if @debug
         if @must_ramp
            millEdgesRamp(aMill, edges, material_thickness, reverse)
         else
            millEdgesPlain(aMill, edges, material_thickness, reverse)
           end
         return true
      rescue Exception => e
         puts e.message
         UI.messagebox(e.message)
         return false
      end # millEdges

      def self.getHZoffset
         hzoffset = PhlatScript.isMetric ? 0.5.mm : 0.02.inch
         if hzoffset > (PhlatScript.multipassDepth / 3)
            hzoffset = PhlatScript.multipassDepth / 3
            # aMill.cncPrintC("hzoffset set to #{hzoffset.to_mm}")
         end
         hzoffset
      end

      # //////////////////
      def self.millEdgesRamp(aMill, edges, material_thickness, reverse = false)
         if edges && !edges.empty?
            begin
               mirror = P.get_safe_reflection_translation
               trans = P.get_safe_origin_translation
               trans *= mirror if Reflection_output
               # virtual o,o point
               if @fakeorigin
                  x = PhlatScript.zerooffsetx
                  y = PhlatScript.zerooffsety
                  vc = Geom::Transformation.translation(Geom::Vector3d.new(-x, -y, 0))
                  vc *= mirror if Reflection_output
                  trans *= vc # apply both translations
               end
               if aMill.getZ < @safeHeight
                  aMill.retract(@safeHeight)
               end

               save_point = nil
               cut_depth = 0
               max_depth = 0
               pass = 0
               pass_depth = 0
               if @optimize && !@g_save_point.nil?
                  edges = optimize(edges, reverse, trans, aMill)
               end # optimize

               points = edges.size # number of edges in this cut
               pass_depth = @tabletop ? material_thickness : 0
               max_depth = @zL
               prog = PhProgressBar.new(edges.length, @group)
               prog.symbols('r', 'R')
               printPass = true

               @tab_top  = 100
               # offset for rapid plunge down to previous pass depth
               hzoffset = getHZoffset
               backtack = false # for debugging

               begin # multipass
                  pass += 1
                  aMill.cncPrintC("Pass: #{pass}") if PhlatScript.useMultipass? && printPass
                  puts "Pass: #{pass}" if PhlatScript.useMultipass? && printPass
                  ecnt = 0
                  edges.each do |phlatcut|
                     ecnt += 1
							isoutside = phlatcut.is_a?(PhlatScript::OutsideCut)
                     prog.update(ecnt)
                     cut_started = false
                     point = nil
                     cut_depth = @zL # not always 0
                     #              puts "cut_depth #{cut_depth}\n"
                     # stuff for backtack fix
                     thestart = true
                     reverse_points = false
                     point_s = point_e = nil # make sure they exist

                     phlatcut.cut_points(reverse) do |cp, cut_factor|
                        prev_pass_depth = pass_depth
                        # cut = ZL - (cutfactor * MT)
                        # safe = ZL+SH  {- safe height is safe margin above material

                        #                  cut_depth = -1.0 * material_thickness * (cut_factor.to_f/100).to_f
                        prev_cut_depth = cut_depth
                        real_cut_depth = cut_depth = @zL - (material_thickness * (cut_factor.to_f / 100).to_f)
                        # store the max depth encountered to determine if another pass is needed
                        max_depth = [max_depth, cut_depth].min
                        # puts "max_depth #{max_depth.to_mm}"   if (pass == 1)

                        if PhlatScript.useMultipass?
                           #                     cut_depth = [cut_depth, (-1.0 * PhlatScript.multipassDepth * pass)].max
                           prev_pass_depth = @zL - (PhlatScript.multipassDepth * (pass - 1))
                           cut_depth = [cut_depth, @zL - (PhlatScript.multipassDepth * pass)].max
                           # puts " cut_depth #{cut_depth.to_mm}  #{pass}\n"   if (pass >= 14)
                           pass_depth = cut_depth
                           #                     puts " pass_depth #{pass_depth.to_mm}\n"
                        end

                        # transform the point if a transformation is provided
                        point = (trans ? cp.transform(trans) : cp)

                        # Jul2016 - trying to fix backtacking on centerlines -
                        # if we detect that this segment ends at the end of the last segment, then swap ends
                        # this will mess up inside/outside cuts, so only use on centerlines
                        if (phlatcut.is_a? CenterLineCut) && (points > 1)
                           if thestart
                              # transformed start and end position
                              if phlatcut.cut_reversed?
                                 point_e = (trans ? phlatcut.edge.start.position.transform(trans) : phlatcut.edge.start.position)
                                 point_s = (trans ? phlatcut.edge.end.position.transform(trans) : phlatcut.edge.end.position)
                              else
                                 point_s = (trans ? phlatcut.edge.start.position.transform(trans) : phlatcut.edge.start.position)
                                 point_e = (trans ? phlatcut.edge.end.position.transform(trans) : phlatcut.edge.end.position)
                              end
                              puts ";#{point_s} #{point_e}   #{save_point} reverse #{reverse} cut_reversed #{phlatcut.cut_reversed?}\n" if backtack
                              reverse_points = false
                              unless save_point.nil? # ignore if 1 edge
                                 if ((point_s.x != save_point.x) || (point_s.y != save_point.y)) &&
                                    ((point_e.x == save_point.x) && (point_e.y == save_point.y))
                                    puts ";   REVERSE points\n" if backtack
                                    reverse_points = true
                                    point.x = point_e.x # use the end point first
                                    point.y = point_e.y
                                 else
                                    reverse_points = false
                                 end
                              end
                              thestart = false
                           else
                              if reverse_points # use the start point second
                                 puts ";   second #{point_s}\n" if backtack
                                 point.x = point_s.x
                                 point.y = point_s.y
                                 reverse_points = false
                              end
                           end
                           puts ";   cp=#{cp}  point #{point}\n" if backtack
                        end

                        # for ramping we need to know the point at the other end of the current edge
                        rev = reverse
                        rev = phlatcut.cut_reversed? if phlatcut.is_a? CenterLineCut # uses internal cut_reversed so we must too
                        otherpoint = if rev
                                        phlatcut.edge.start.position
                                     else
                                        phlatcut.edge.end.position
                                     end
                        otherpoint = (trans ? otherpoint.transform(trans) : otherpoint)

                        #               if (phlatcut.kind_of? CenterLineCut)
                        #                  puts "#{phlatcut} start#{point} end#{otherpoint} x#{point.x.to_mm} y#{point.y.to_mm} rv#{reverse}" if (@debug)
                        #               end

                        # retract if this cut does not start where the last one ended
                        if save_point.nil? || (save_point.x != point.x) || (save_point.y != point.y) || (save_point.z != cut_depth)
                           if !cut_started
                              if PhlatScript.useMultipass? # multipass retract avoid by Yoram and swarfer
                                 # If it's peck drilling we want it to retract after each plunge to clear the tool
                                 if phlatcut.is_a? PlungeCut
                                    if pass == 1
                                       # puts "plunge multi #{phlatcut}"
                                       aMill.safemove(point.x, point.y)
                                       #if aMill.notequal(aMill.getZ, 2*@safeHeight)
                                       #   aMill.move(point.x, point.y)
                                       #else
                                       #   aMill.move(point.x, point.y, 2*@safeHeight,1,'G0')
                                       #   aMill.retract(@safeHeight)
                                       #end
                                       
                                       diam = phlatcut.diameter > 0 ? phlatcut.diameter : @current_bit_diameter
                                       if phlatcut.angle > 0
                                          ang = phlatcut.angle
                                          cdia = phlatcut.cdiameter
                                          aMill.plungebore(point.x, point.y, @zL, max_depth, diam, ang, cdia)
                                       else
                                          if phlatcut.angle < 0
                                             ang = phlatcut.angle
                                             cdiam = phlatcut.cdiameter
                                             cdepth = phlatcut.cdepth
                                             aMill.plungebore(point.x, point.y, @zL, max_depth, diam, ang, cdiam, cdepth)
                                          else
                                             c_depth = @zL - (material_thickness * (cut_factor.to_f / 100).to_f)
                                             # puts "plunge  material_thickness #{material_thickness.to_mm} cutfactor #{cut_factor} c_depth #{c_depth.to_mm} diam #{diam.to_mm}"
                                             aMill.plungebore(point.x, point.y, @zL, c_depth, diam)
                                          end
                                       end
                                       printPass = false # prevent print pass comments because holes are self contained and empty passes freak users out
                                    end
                                 else
                                    if (phlatcut.is_a? CenterLineCut) || (phlatcut.is_a? PocketCut)
                                       # for these cuts we must retract else we get collisions with existing material
                                       # this results from commenting the code in lines 203-205 to stop using 'oldmethod'
                                       # for pockets.

                                       if points > 1 # if cutting more than 1 edge at a time, must retract
                                          aMill.cncPrintC('points > 1') if @debug
                                          if !save_point.nil? && ((save_point.x == point.x) && (save_point.y == point.y))
                                             aMill.cncPrintC('retract prevented in ramp') if @debug
                                          else
                                             aMill.safemove(point.x, point.y)
                                             #if aMill.notequal(aMill.getZ, 2*@safeHeight)
                                             #   aMill.retract(@safeHeight) if aMill.getZ < @safeHeight
                                             #   aMill.move(point.x, point.y)                                             
                                             #else
                                             #   aMill.move(point.x, point.y, 2*@safeHeight,1, 'G0')
                                             #   aMill.retract(@safeHeight) 
                                             #end
                                                
                                             if (prev_pass_depth < @zL) && (cut_depth < prev_pass_depth)
                                                if aMill.plung(prev_pass_depth + hzoffset, 1, 'G0', false)
                                                   aMill.cncPrintC('plunged to previous pass before ramp') if @debug
                                                end
                                             end
                                          end
                                          aMill.ramp(@rampangle, otherpoint, cut_depth, PhlatScript.plungeRate)
                                       else
                                          aMill.cncPrintC('points = 1') if @debug
                                          if PhlatScript.useMultipass? && phlatcut.is_a?(CenterLineCut)
                                             # do simple ramp to depth
                                             # do not use .safemove here
                                             if aMill.notequal(aMill.getZ, 2*@safeHeight)
                                                aMill.move(point.x, point.y) if pass == 1
                                             else
                                                aMill.move(point.x, point.y, 2*@safeHeight,1,'G0') if pass == 1
                                                aMill.retract(@safeHeight)
                                             end
                                             aMill.cncPrintC('RAMP to depth') if @debug
                                             aMill.ramp(@rampangle, otherpoint, cut_depth, PhlatScript.plungeRate,true) #set nodist true
                                          else
                                             aMill.cncPrintC(' normal move and ramp to cut_depth') if @debug
                                             aMill.move(point.x, point.y)
                                             if (prev_pass_depth < @zL) && (cut_depth < prev_pass_depth)
                                                if aMill.plung(prev_pass_depth + hzoffset, 1, 'G0', false)
                                                   aMill.cncPrintC('plunged to previous pass') if @debug
                                                end
                                             end
                                             aMill.ramp(@rampangle, otherpoint, cut_depth, PhlatScript.plungeRate)
                                          end
                                       end
                                    else
                                       # If it's not a peck drilling we don't need retract
                                       # do not use .safemove here
                                       if aMill.getZ > @safeHeight
                                          aMill.move(point.x, point.y, 2*@safeHeight,PhlatScript.plungeRate,'G0')
                                          aMill.retract(@safeHeight)
                                       else
                                          aMill.move(point.x, point.y, aMill.getZ,PhlatScript.plungeRate,'G0')
                                       end
                                       if (phlatcut.is_a? PhlatArc) && phlatcut.is_arc?
                                          center = phlatcut.center
                                          tcenter = (trans ? center.transform(trans) : center) # transform if needed
                                          puts "arc ramping in tcenter #{tcenter}" if @debug
                                          g3 = reverse ? !phlatcut.g3? : phlatcut.g3?
                                          puts "ramping multi g3=#{g3}" if @debug
                                          cmnd = g3 ? 'G03' : 'G02'
														
														# v1.5 - only feedadjust on outside arcs if they are inside a shape
														fawas = dofeedadjust(phlatcut.class, g3)
                                          aMill.ramplimitArc(@rampangle, otherpoint, phlatcut.radius, tcenter, cut_depth, PhlatScript.plungeRate, cmnd)
														$phoptions.feed_adjust = fawas
                                       else
                                          aMill.ramp(@rampangle, otherpoint, cut_depth, PhlatScript.plungeRate)
                                       end
                                    end
                                 end # if else plungcut
                              else # NOT multipass
                                 aMill.safemove(point.x, point.y)
                                 #if aMill.getZ < @safeHeight
                                 #   aMill.retract(@safeHeight)
                                 #end
                                 #aMill.move(point.x, point.y, aMill.getZ, PhlatScript.plungeRate, 'G0')
                                 #if aMill.getZ > @safeHeight
                                 #   aMill.retract(@safeHeight)
                                 #end
                                 if phlatcut.is_a? PlungeCut
                                    # puts "plunge #{phlatcut}"
                                    # puts "   plunge dia #{phlatcut.diameter}"
                                    diam = phlatcut.diameter > 0 ? phlatcut.diameter : @current_bit_diameter
                                    if phlatcut.angle > 0
                                       ang = phlatcut.angle
                                       cdia = phlatcut.cdiameter
                                       aMill.plungebore(point.x, point.y, @zL, cut_depth, diam, ang, cdia)
                                    else
                                       if phlatcut.angle < 0
                                          ang = phlatcut.angle
                                          cdiam = phlatcut.cdiameter
                                          cdepth = phlatcut.cdepth
                                          aMill.plungebore(point.x, point.y, @zL, cut_depth, diam, ang, cdiam, cdepth)
                                       else
                                          aMill.plungebore(point.x, point.y, @zL, cut_depth, diam)
                                       end
                                    end
                                 #                           else
                                 #                              aMill.plung(cut_depth, PhlatScript.plungeRate)
                                 #                           end
                                 else

                                    if (phlatcut.is_a? PhlatArc) && phlatcut.is_arc?
                                       center = phlatcut.center
                                       tcenter = (trans ? center.transform(trans) : center) # transform if needed
                                       puts "arc ramping in tcenter #{tcenter}" if @debug
                                       g3 = reverse ? !phlatcut.g3? : phlatcut.g3?
                                       cmnd = g3 ? 'G03' : 'G02'
													
													# v1.5 - only feedadjust on outside arcs if they are inside a shape
													fawas = dofeedadjust(phlatcut.class, g3)													
                                       aMill.ramplimitArc(@rampangle, otherpoint, phlatcut.radius, tcenter, cut_depth, PhlatScript.plungeRate, cmnd)
													$phoptions.feed_adjust =  fawas		
                                    else
                                       puts "straight ramp to #{sprintf("%0.3f",cut_depth.to_mm)}" if @debug
                                       aMill.ramp(@rampangle, otherpoint, cut_depth, PhlatScript.plungeRate)
                                    end
                                 end # if plungecut
                              end # if else multipass
                           else # cut in progress
                              if (phlatcut.is_a? PhlatArc) && phlatcut.is_arc? && (save_point.nil? || (save_point.x != point.x) || (save_point.y != point.y))
                                 if phlatcut.is_a?(PhlatScript::TabCut)
                                    puts 'ARC tabcut with ramp ' if @debug
                                    puts 'VTAB' if phlatcut.vtab? && @debug
                                    puts " p cut_depth #{prev_cut_depth.to_mm}"                  if @debug
                                    puts "   cut_depth #{cut_depth.to_mm}"                       if @debug
                                    puts "        point #{point.x}  #{point.y} #{point.z}"       if @debug
                                    puts "  other point #{otherpoint.x}  #{otherpoint.y} #{otherpoint.z}" if @debug
                                 end

                                 g3 = reverse ? !phlatcut.g3? : phlatcut.g3?
                                 if @ramp_next
                                    puts 'RAMP_NEXT true for arc, ramping then arcing' if @debug
                                    center = phlatcut.center
                                    tcenter = (trans ? center.transform(trans) : center) # transform if needed
                                    puts "arc ramping in tcenter #{tcenter}" if @debug
                                    cmnd = g3 ? 'G03' : 'G02'
												fawas = dofeedadjust(phlatcut.class, g3)
                                    aMill.ramplimitArc(@rampangle, otherpoint, phlatcut.radius, tcenter, cut_depth, PhlatScript.plungeRate, cmnd)
												$phoptions.feed_adjust = fawas
                                    @ramp_next = false
                                 end

                                 center = phlatcut.center
                                 unless (center.x != 0.0) && (center.y != 0.0)
                                    raise 'ARC HAS NO CENTER, PLEASE RECODE THIS FILE'
                                 end
                                 tcenter = (trans ? center.transform(trans) : center) # transform if needed
                                 puts "tcenter #{tcenter}" if @debug
											fawas = dofeedadjust(phlatcut.class, g3)
                                 if (phlatcut.is_a? PhlatScript::TabCut) && phlatcut.vtab? && $phoptions.use_vtab_speed_limit?
                                    # if speed limit is enabled for arc vtabs set the feed rate to the plunge rate here
                                    aMill.arcmoveij(point.x, point.y, tcenter.x, tcenter.y, phlatcut.radius, g3, cut_depth, PhlatScript.plungeRate)
                                 # aMill.arcmove(point.x, point.y, phlatcut.radius, g3, cut_depth, PhlatScript.plungeRate)
                                 else
                                    puts "ARC to #{point.x}  #{point.y} #{cut_depth.to_mm}" if @debug
                                    # aMill.arcmove(point.x, point.y, phlatcut.radius, g3, cut_depth)
                                    aMill.arcmoveij(point.x, point.y, tcenter.x, tcenter.y, phlatcut.radius, g3, cut_depth)
                                 end
											$phoptions.feed_adjust = fawas
                              else  # not arc
                                 if @must_ramp
                                    #                           aMill.ramp(otherpoint, cut_depth, PhlatScript.plungeRate)
                                    # need to detect the plunge end of a tab, save the height, and flag it for 'ramp next time'
                                    # do not ramp for vtabs, they are their own ramp!
                                    if (phlatcut.is_a? PhlatScript::TabCut) && !phlatcut.vtab?
                                       puts "Must ramp and tab pass=#{pass}" if @debug
                                       puts 'VTAB' if phlatcut.vtab? && @debug
                                       puts " p pass depth #{prev_pass_depth.to_mm}"                if @debug
                                       puts " p cut_depth #{prev_cut_depth.to_mm}"                  if @debug
                                       puts "   cut_depth #{cut_depth.to_mm}"                       if @debug
                                       puts "        point #{point.x}  #{point.y} #{point.z}"       if @debug
                                       puts "  other point #{otherpoint.x}  #{otherpoint.y} #{otherpoint.z}" if @debug
                                       # must ramp and tab
                                       # p cut_depth -10.5
                                       #   cut_depth -5.0
                                       #        point 61.5mm  31.5mm 0.0mm
                                       #  other point 61.5mm  38.5mm 0.0mm
                                       # must do this move
                                       if ((point.x != otherpoint.x) || (point.y != otherpoint.y)) && (prev_cut_depth < cut_depth)
                                          puts " RAMP moving up onto tab #{point.x.to_mm} #{point.y.to_mm} #{cut_depth.to_mm}" if @debug
                                          @tab_top = cut_depth
                                          aMill.move(point.x, point.y, cut_depth)
                                       end
                                       # must ramp and tab
                                       # p cut_depth -5.0
                                       #   cut_depth -5.0
                                       #        point 61.5mm  38.5mm 0.0mm
                                       #  other point 61.5mm  38.5mm 0.0mm
                                       # do this move
                                       if ((point.x == otherpoint.x) && (point.y == otherpoint.y)) && (prev_cut_depth == cut_depth)
                                          puts "  RAMP moving tab #{point.x.to_mm} #{point.y.to_mm} #{cut_depth.to_mm}" if @debug
                                          aMill.move(point.x, point.y, cut_depth)
                                       end
                                       # must ramp and tab
                                       # p cut_depth -5.0
                                       #   cut_depth -10.5
                                       #        point 61.5mm  38.5mm 0.0mm
                                       #  other point 61.5mm  38.5mm 0.0mm
                                       # set ramp next move
                                       if (point.x == otherpoint.x) && (point.y == otherpoint.y) && (prev_cut_depth > cut_depth)
                                          puts '   setting ramp_next true' if @debug
                                          @ramp_next = true && !phlatcut.vtab?
                                          # if coming down on the trailing edge of a tab, and ramping, then
                                          # we can rapid down to NEAR the previous pass level and ramp from there
                                          if PhlatScript.useMultipass?
                                             if (prev_pass_depth < prev_cut_depth) && (prev_cut_depth == @tab_top)
                                                if PhlatScript.multipassDepth <= 0.25.mm
                                                   cloffset = PhlatScript.multipassDepth / 2
                                                else
                                                   cloffset = 0.25.mm
                                                end
                                                aMill.cncPrintC("PLUNGE to previous pass depth #{prev_pass_depth.to_mm}") if @debug
                                                aMill.plung(prev_pass_depth + cloffset, PhlatScript.feedRate, 'G0')
                                             end
                                          end
                                          #                                 @ramp_depth = cut_depth  # where it starts
                                       end
                                    else # not a tab cut
                                       if @ramp_next
                                          puts "ramping ramp_next true #{point.x.to_mm} #{point.y.to_mm} #{cut_depth.to_mm}  tab_top #{@tab_top.to_mm} " if @debug
                                          aMill.ramp(@rampangle, otherpoint, cut_depth, PhlatScript.plungeRate)
                                          aMill.move(point.x, point.y, cut_depth)
                                          @ramp_next = false
                                       else
                                          if (points == 1) && PhlatScript.useMultipass? && phlatcut.is_a?(CenterLineCut)
                                             aMill.cncPrintC('if last pass, do move') if @debug
                                             if (real_cut_depth - cut_depth).abs < 0.0001
                                                aMill.cncPrintC('doing move') if @debug
                                                aMill.move(point.x, point.y, cut_depth)
                                             end
                                          # aMill.ramp(@rampangle,otherpoint, cut_depth, PhlatScript.plungeRate)
                                          else
                                             # puts "plain move, not tab, not ramp_next #{point.x.to_mm} #{point.y.to_mm} #{cut_depth.to_mm}" if (@debug)
                                             aMill.setComment('centerline plain move') if phlatcut.is_a?(CenterLineCut) && @debug
                                             aMill.retract(@safeHeight) if aMill.getZ > @safeHeight
                                             aMill.move(point.x, point.y, cut_depth)
                                          end
                                       end
                                    end
                                 else # just move
                                    puts 'just move' if @debug
                                    aMill.cncPrintC('just move in ramp') if @debug
                                    aMill.move(point.x, point.y, cut_depth)
                                 end # if must_ramp
                              end
                           end # if !cutstarted
                        end # if point != savepoint
                        cut_started = true
                        save_point = point.nil? ? nil : Geom::Point3d.new(point.x, point.y, cut_depth)
                     end # phlatcut.cut_points.each
                  end # edges.each
                  if pass > ((material_thickness / PhlatScript.multipassDepth) + 2) # just in case it runs away, mainly debugging
                     rem =  (pass_depth - max_depth).abs
                     puts "breaking at #{rem} remaining"
                     aMill.cncPrintC("BREAK pass #{pass}")
                     puts "BREAK large pass #{pass}  too many passes for mat thickness\n"
                     break
                  end
                  # new condition, detect 'close enough' to max_depth instead of equality,
                  # for some multipass settings this would result in an extra pass with the same depth
                  #         rem =  (pass_depth-max_depth).abs
                  #         puts "remaining #{rem}"
               end until (!PhlatScript.useMultipass? || ((pass_depth - max_depth).abs < 0.0001))
               @g_save_point = save_point unless save_point.nil? # for optimizer
            rescue Exception => e
               raise e.message
               # UI.messagebox "Exception in millEdges "+$! + e.backtrace.to_s
            end
         else
            puts 'no edges in milledgesramp' if @debug
         end # if edges
      end # millEdgesRamp
      #---------------------------------------------------------------------------------------------

      ## the original milledges, no ramp handling
      def self.millEdgesPlain(aMill, edges, material_thickness, reverse = false)
         caller_line = caller.first
         #puts "milledgesPlain : #{caller_line}"         if @debug

         if edges && !edges.empty?
            begin
               puts "millEdgesPlain reverse=#{reverse}" if @debug

               mirror = P.get_safe_reflection_translation
               trans = P.get_safe_origin_translation
               trans *= mirror if Reflection_output
               # virtual o,o point
               if @fakeorigin
                  x = PhlatScript.zerooffsetx
                  y = PhlatScript.zerooffsety
                  vc = Geom::Transformation.translation(Geom::Vector3d.new(-x, -y, 0))
                  vc *= mirror if Reflection_output
                  trans *= vc # apply both translations
                  # use vc as an additional transform
               end
               if aMill.getZ < @safeHeight
                  aMill.retract(@safeHeight)
               end

               save_point = nil
               cut_depth = 0
               max_depth = 0
               pass = 0
               pass_depth = 0
               if @optimize && !@g_save_point.nil?
                  edges = optimize(edges, reverse, trans, aMill)
               end # optimize

               #      edges = dragknife(edges,reverse,trans)

               points = edges.size
               pass_depth = if @tabletop
                               material_thickness
                            else
                               0
                            end
               max_depth = @zL
               prog = PhProgressBar.new(edges.length, @group)
               prog.symbols('e', 'E')
               printPass = true
               # this is the offset for the plunge down to previous pass depth so the tool will not hit the surface
               hzoffset = getHZoffset
               backtack = false # for debugging
               begin # multipass
                  pass += 1
                  puts "pass #{pass}\n" if backtack
                  aMill.cncPrintC("Pass: #{pass}") if PhlatScript.useMultipass? && printPass
                  ecnt = 0
                  edges.each do |phlatcut|
                     ecnt += 1
                     prog.update(ecnt)
                     cut_started = false
                     point = nil
                     cut_depth = @zL # not always 0
                     #              puts "cut_depth #{cut_depth}\n"

                     thestart = true
                     reverse_points = false
                     point_s = point_e = nil # make sure they exist

                     phlatcut.cut_points(reverse) do |cp, cut_factor|
                        prev_pass_depth = pass_depth
                        # cut = ZL - (cutfactor * MT)
                        # safe = ZL+SH  {- safe height is safe margin above material

                        #                  cut_depth = -1.0 * material_thickness * (cut_factor.to_f/100).to_f
                        prev_cut_depth = cut_depth
                        cut_depth = @zL - (material_thickness * (cut_factor.to_f / 100).to_f)
                        # store the max depth encountered to determine if another pass is needed
                        max_depth = [max_depth, cut_depth].min

                        if PhlatScript.useMultipass?
                           #                     cut_depth = [cut_depth, (-1.0 * PhlatScript.multipassDepth * pass)].max
                           prev_pass_depth = @zL - (PhlatScript.multipassDepth * (pass - 1))
                           cut_depth = [cut_depth, @zL - (PhlatScript.multipassDepth * pass)].max
                           #                     puts " cut_depth #{cut_depth.to_mm}\n"
                           pass_depth = cut_depth
                           #                     puts " pass_depth #{pass_depth.to_mm}\n"
                        end

                        # transform the point if a transformation is provided
                        point = (trans ? cp.transform(trans) : cp)
                        puts "point #{point}\n" if backtack
                        # Jul2016 - trying to fix backtacking on centerlines -
                        # if we detect that this segment ends at the end of the last segment, then swap ends
                        # this will mess up inside/outside cuts, so only use on centerlines
                        if (phlatcut.is_a? CenterLineCut) && (points > 1)
                           if thestart
                              # transformed start and end position
                              if phlatcut.cut_reversed?
                                 puts 'reversed ' if backtack
                                 point_e = (trans ? phlatcut.edge.start.position.transform(trans) : phlatcut.edge.start.position)
                                 point_s = (trans ? phlatcut.edge.end.position.transform(trans) : phlatcut.edge.end.position)
                              else
                                 puts 'not reversed ' if backtack
                                 point_s = (trans ? phlatcut.edge.start.position.transform(trans) : phlatcut.edge.start.position)
                                 point_e = (trans ? phlatcut.edge.end.position.transform(trans) : phlatcut.edge.end.position)
                              end
                              puts "got _s #{point_s} _e #{point_e}\n" if backtack
                              #                     if (reverse)
                              #                        puts "   reversing ps pe\n" if (backtack)
                              #                        pe = point_e
                              #                        point_e = point_s
                              #                        point_s = pe
                              #                     end
                              puts ";#{point_s} #{point_e}   #{save_point} reverse #{reverse} cut_reversed #{phlatcut.cut_reversed?}\n" if backtack
                              reverse_points = false
                              unless save_point.nil? # ignore if 1 edge
                                 if ((point_s.x != save_point.x) || (point_s.y != save_point.y)) &&
                                    ((point_e.x == save_point.x) && (point_e.y == save_point.y))
                                    puts ";   REVERSE points\n" if backtack
                                    reverse_points = true
                                    point.x = point_e.x # use the end point first
                                    point.y = point_e.y
                                 else
                                    reverse_points = false
                                 end
                              end
                              thestart = false
                           else
                              if reverse_points # use the start point second
                                 puts ";   second #{point_s}\n" if backtack
                                 point.x = point_s.x
                                 point.y = point_s.y
                                 reverse_points = false
                              end
                           end
                           puts ";   using point #{point}\n" if backtack
                        end

                        # retract if this cut does not start where the last one ended
                        if save_point.nil? || (save_point.x != point.x) || (save_point.y != point.y) || (save_point.z != cut_depth)
                           if !cut_started
                              if PhlatScript.useMultipass? # multipass retract avoid by Yoram and swarfer
                                 # If it's peck drilling we want it to retract after each plunge to clear the tool
                                 if phlatcut.is_a? PlungeCut
                                    if pass == 1
                                       # puts "plunge multi #{phlatcut}"
                                       if aMill.getZ < @safeHeight
                                          aMill.retract(@safeHeight)
                                          aMill.move(point.x, point.y)
                                       else
                                          aMill.move(point.x, point.y, aMill.getZ,1,'G0')
                                       end
                                       # aMill.plung(cut_depth)
                                       diam = phlatcut.diameter > 0 ? phlatcut.diameter : @current_bit_diameter

                                       if phlatcut.angle > 0
                                          ang = phlatcut.angle
                                          cdiam = phlatcut.cdiameter
                                          aMill.plungebore(point.x, point.y, @zL, max_depth, diam, ang, cdiam)
                                       else
                                          if phlatcut.angle < 0
                                             ang = phlatcut.angle
                                             cdiam = phlatcut.cdiameter
                                             cdepth = phlatcut.cdepth
                                             aMill.plungebore(point.x, point.y, @zL, max_depth, diam, ang, cdiam, cdepth)
                                          else
                                             c_depth = @zL - (material_thickness * (cut_factor.to_f / 100).to_f)
                                             aMill.plungebore(point.x, point.y, @zL, c_depth, diam)
                                          end
                                       end
                                       # puts "plunge  material_thickness #{material_thickness.to_mm} cutfactor #{cut_factor} c_depth #{c_depth.to_mm} diam #{diam.to_mm}"
                                       printPass = false # prevent print pass comments because holes are self contained and empty passes freak users out
                                    end
                                 else
                                    if (phlatcut.is_a? CenterLineCut) || (phlatcut.is_a? PocketCut)
                                       # for these cuts we must retract else we get collisions with existing material
                                       # this results from commenting the code in lines 203-205 to stop using 'oldmethod'
                                       # for pockets.
                                       if pass == 1
                                          if (phlatcut.is_a? PocketCut)
                                             aMill.cncPrintC('Pocket')
                                          else
                                             aMill.cncPrintC('Centerline')
                                          end
                                       end
                                       
                                       
                                       retractp = false
                                       if points > 1 # if cutting more than 1 edge at a time, must retract
                                          # puts "retracting #{save_point.x} #{save_point.y}  #{point.x} #{point.y}"  if (!save_point.nil?)
                                          # if we are at the same point, do not retract
                                          if !save_point.nil? && ((save_point.x == point.x) && (save_point.y == point.y))
                                             aMill.cncPrintC('retract prevented') if @debug
                                             retractp = true
                                          else
                                             aMill.retract(@safeHeight) if aMill.getZ < @safeHeight
                                             retractp = false           if aMill.getZ < @safeHeight
                                          end
                                       else # only 1 segment, use optimal single direction cut path
                                          # if multipass and 1 edge and not finished , then partly retract
                                          # puts "#{PhlatScript.useMultipass?} #{points==1} #{pass>1} #{(pass_depth-max_depth).abs >= 0} #{phlatcut.kind_of?(CenterLineCut)}"
                                          if PhlatScript.useMultipass? && (points == 1) &&
                                             (pass > 1) && ((pass_depth - max_depth).abs >= 0.0) &&
                                             phlatcut.is_a?(CenterLineCut)
                                             aMill.setComment("PARTIAL RETRACT") if @debug
                                             aMill.retract(prev_pass_depth + hzoffset)
                                             ccmd = 'G00' # must be 00 to prevent aMill.move overriding the cmd because zo is not safe height
                                          end
                                       end
                                       if ccmd
                                          aMill.setComment("RAPID #{ccmd}") if @debug
                                          aMill.move(point.x, point.y, prev_pass_depth + hzoffset, PhlatScript.feedRate, 'G0')
                                          ccmd = nil
                                       else
                                          # puts "moving #{save_point.x} #{save_point.y}  #{point.x} #{point.y}"  if (!save_point.nil?)
                                          aMill.safemove(point.x, point.y)
                                          #if aMill.getZ > @safeHeight
                                          #   aMill.move(point.x, point.y, 2*@safeHeight,1,'G0')
                                          #   aMill.retract(@safeHeight)
                                          #else
                                          #   aMill.move(point.x, point.y)
                                          #end
                                       end
                                       # aMill.cncPrintC("cut_d #{cut_depth.to_mm}   prev #{prev_pass_depth.to_mm}")
                                       # can we rapid down to near the previous pass depth?
                                       if !retractp && (prev_pass_depth < @zL) && (cut_depth < prev_pass_depth)
                                          if aMill.plung(prev_pass_depth + hzoffset, 1, 'G0', false)
                                             aMill.cncPrintC('Plunged to previous pass') if !PhlatScript.useLaser?
                                          end
                                       end
                                       aMill.plung(cut_depth, PhlatScript.plungeRate)
                                    else
                                       # If it's not a peck drilling we don't need retract
                                       # we do if the previous move was a G53
                                       if aMill.getZ > @safeHeight
                                          aMill.move(point.x, point.y, 2*@safeHeight,1,'G0')
                                          aMill.retract(@safeHeight)
                                       end
                                       aMill.move(point.x, point.y)
                                       aMill.plung(cut_depth, PhlatScript.plungeRate)
                                    end
                                 end # if else plungcut
                              else # NOT multipass
                                 if (phlatcut.is_a? PocketCut)
                                    aMill.cncPrintC('Pocket')
                                 else
                                    if phlatcut.is_a? CenterLineCut
                                       aMill.cncPrintC('Centerline')
                                    end
                                 end
                                 aMill.safemove(point.x, point.y)
                                 #if aMill.getZ < @safeHeight
                                 #   aMill.retract(@safeHeight)
                                 #   aMill.move(point.x, point.y)
                                 #else
                                 #   aMill.move(point.x, point.y, aMill.getZ, PhlatScript.plungeRate,'G0')
                                 #   aMill.retract(@safeHeight)                                 
                                 #end
                                 if phlatcut.is_a? PlungeCut
                                    # puts "plunge #{phlatcut}"
                                    # puts "   plunge dia #{phlatcut.diameter}"
                                    diam = phlatcut.diameter > 0 ? phlatcut.diameter : @current_bit_diameter
                                    if phlatcut.angle > 0
                                       ang = phlatcut.angle
                                       cdiam = phlatcut.cdiameter
                                       aMill.plungebore(point.x, point.y, @zL, cut_depth, diam, ang, cdiam)
                                    else
                                       if phlatcut.angle < 0
                                          ang = phlatcut.angle
                                          cdiam = phlatcut.cdiameter
                                          cdepth = phlatcut.cdepth
                                          aMill.plungebore(point.x, point.y, @zL, cut_depth, diam, ang, cdiam, cdepth)
                                       else
                                          aMill.plungebore(point.x, point.y, @zL, cut_depth, diam)
                                       end
                                    end
                                 else
                                    aMill.plung(cut_depth, PhlatScript.plungeRate)
                                 end # if plungecut
                              end # if else multipass
                           else # cut in progress
                              if (phlatcut.is_a? PhlatArc) && phlatcut.is_arc? && (save_point.nil? || (save_point.x != point.x) || (save_point.y != point.y))
                                 # something odd with this reverse thing, for some arcs it gets the wrong direction, outputting G3 for clockwise cuts instead of G2
                                 g3 = reverse ? !phlatcut.g3? : phlatcut.g3?
                                 cutkind = phlatcut.class                                                    
                                 puts "reverse #{reverse} .g3 #{phlatcut.g3?} cutkind=#{cutkind}  ===  g3=#{g3}"  if @debugarc

                                 center = phlatcut.center
                                 unless (center.x != 0.0) && (center.y != 0.0)
                                    raise 'ARC HAS NO CENTER, PLEASE RECODE THIS FILE'
                                 end
                                 tcenter = (trans ? center.transform(trans) : center) # transform if needed
											# v1.5 - only feedadjust on outside arcs if they are inside a shape
											fawas = dofeedadjust(phlatcut.class, g3)
                                 if (phlatcut.is_a? PhlatScript::TabCut) && phlatcut.vtab? && $phoptions.use_vtab_speed_limit?
                                    # if speed limit is enabled for arc vtabs set the feed rate to the plunge rate here
                                    aMill.arcmoveij(point.x, point.y, tcenter.x, tcenter.y, phlatcut.radius, g3, cut_depth, PhlatScript.plungeRate)
                                 # aMill.arcmove(point.x, point.y, phlatcut.radius, g3, cut_depth, PhlatScript.plungeRate)
                                 else
                                    # aMill.arcmove(point.x, point.y, phlatcut.radius, g3, cut_depth)
                                    aMill.arcmoveij(point.x, point.y, tcenter.x, tcenter.y, phlatcut.radius, g3, cut_depth)
                                 end
											$phoptions.feed_adjust = fawas
                              else
                                 aMill.move(point.x, point.y, cut_depth)
                              end
                           end # if !cutstarted
                        end # if point != savepoint
                        cut_started = true
                        save_point = point.nil? ? nil : Geom::Point3d.new(point.x, point.y, cut_depth)
                     end
                  end # edges.each
                  if pass > ((material_thickness / PhlatScript.multipassDepth) + 2) # just in case it runs away, mainly debugging
                     aMill.cncPrintC("BREAK pass #{pass}")
                     puts "BREAK large pass #{pass}\n"
                     break
                  end
                  # new condition, detect 'close enough' to max_depth instead of equality,
                  # for some multipass settings this would result in an extra pass with the same depth
               end until (!PhlatScript.useMultipass? || ((pass_depth - max_depth).abs < 0.0001))

               @g_save_point = save_point unless save_point.nil? # for optimizer
            rescue Exception => e
               raise e.message
               # UI.messagebox "Exception in millEdges "+$! + e.backtrace.to_s
            end
            aMill.retract(@safeHeight)
         end # if edges
         #puts "milledgesplain end\n" if @debug
      end # milledges without ramp

      def self.enter_file_dialog(_model = Sketchup.active_model)
         output_directory_name = PhlatScript.cncFileDir
         output_filename = PhlatScript.cncFileName
         status = false
         result = UI.savepanel(PhlatScript.getString('Save CNC File'), output_directory_name, output_filename)
         unless result.nil?
            # if there isn't a file extension set it to the default
            result += $phoptions.default_file_ext if File.extname(result).empty?
            PhlatScript.cncFile = result
            PhlatScript.checkParens(result, 'Output File')
            status = true
         end
         status
      end

      def self.points_in_points(test_pts, bounding_pts)
         fits = true
         test_pts.each do |pt|
            next unless fits
            fits = Geom.point_in_polygon_2D(pt, bounding_pts, false)
         end
         fits
      end

   end # class GcodeUtil
end #module
# $Id$

# return true if the 2 edges given share an end point
#    def GcodeUtil.sharepoint(fe,se)
#       fes = fe.start.position
#       fee = fe.end.position
#       ses = se.start.position
#       see = se.end.position
#       if ( ((fes.x - ses.x).abs < 0.0001) && ((fes.y - ses.y).abs < 0.0001) ) ||
#          ( ((fes.x - see.x).abs < 0.0001) && ((fes.y - see.y).abs < 0.0001) ) ||
#          ( ((fee.x - ses.x).abs < 0.0001) && ((fee.y - ses.y).abs < 0.0001) ) ||
#          ( ((fee.x - see.x).abs < 0.0001) && ((fee.y - see.y).abs < 0.0001) )
#          return true
#       else
#          return false
#       end
#    end
