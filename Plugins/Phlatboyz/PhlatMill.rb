require 'sketchup.rb'
# require 'Phlatboyz/Constants.rb'
# see note at end of file
module PhlatScript
   RAMPMULT = 5    # rampdist = bitdiam * RAMPMULT

   class PhlatMill
      # Open an output file and set up initial state
      def initialize(output_file_name = nil, min_max_array = nil)
         # current_Feed_Rate = model.get_attribute Dict_name, $dict_Feed_Rate , nil
         # current_Plunge_Feed = model.get_attribute Dict_name, $dict_Plunge_Feed , nil
         @cz = 1e10     # user bug, if the offset is at 0,0 and there is a plunge hole there, XY were not output
         @cx = 1e10     # so set these to non0 to force the output of a goto 0,0
         @cy = 1e10
         @cs = 0.0
         @cc = ''
         @debug = true # if true then a LOT of stuff will appear in the ruby console
         @debugc = ''  # a place to put debugging comments in subfunctions like getfuzzyystep
         @debugramp = false
         puts "debug true in PhlatMill.rb\n" if @debug || @debugramp
         @pcomment = '' #see setComment
         @quarters = $phoptions.quarter_arcs? # use quarter circles in plunge bores?  defaults to true
         # manual user options - if they find this they can use it (-:
         @quickpeck = $phoptions.quick_peck?   # if true will not retract to surface when peck drilling, withdraw only 0.5mm
         @canneddrill = false
         @depthfirst = $phoptions.depth_first? # depth first is old way, false gives diam first, spiralout()
         @fastapproach = true
         @laser = PhlatScript.useLaser? # frikken lasers!
         @laser_grbl_mode = $phoptions.laser_GRBL_mode? # affects how holes are coded
         @laser_power_mode = $phoptions.laser_power_mode? # M4 if true, M3 is false
         @servo = PhlatScript.useServo?
         if @servo
            # servo overrides laser and ramping and multipass
            @laser = false
            PhlatScript.mustramp = false
            PhlatScript.useMultipass = false
            $phoptions.feed_adjust = false # dont use arc feed adjust
         end   
         @servo_up = $phoptions.servo_up.to_i      # must be integers
         @servo_down = $phoptions.servo_down.to_i
         if @servo_up > @servo_down
            #servo_up must be less than servo_down because servo 0 is pen UP park position
            t = @servo_up
            @servo_up = @servo_down
            @servo_down = t
         end
            
         @servo_time = $phoptions.servo_time
         @penPos = @servo_up
         @cboreinner = 0 # diameter of inner hole for counterbores
         #
         @max_x = 48.0
         @min_x = -48.0
         @max_y = 22.0
         @min_y = -22.0
         @max_z = 1.0
         @min_z = -1.0
         unless min_max_array.nil?
            @min_x = min_max_array[0]
            @max_x = min_max_array[1]
            @min_y = min_max_array[2]
            @max_y = min_max_array[3]
            @min_z = min_max_array[4]
            @max_z = min_max_array[5]
         end
         @no_move_count = 0
         @gforce = $phoptions.gforce? # always output all Gcodes, for Marlin firmware, if true
         @spindle_speed = PhlatScript.spindleSpeed
         @retract_depth = PhlatScript.safeTravel.to_f
         @table_flag = false # true if tabletop is zZero
         #      @mill_depth  = -0.35
         @speed_curr  = PhlatScript.feedRate
         @speed_plung = PhlatScript.plungeRate
         @material_w = PhlatScript.safeWidth
         @material_h = PhlatScript.safeHeight
         @material_thickness = PhlatScript.materialThickness
         @multidepth = PhlatScript.multipassDepth
         @bit_diameter = 0 # swarfer: need it often enough to be global
         @rampdist = 0 # distance over which to ramp, set when bitdiameter is set

         @comment = PhlatScript.commentText
         @extr = '-'
         @cmd_linear = 'G01'  # Linear interpolation
         @cmd_rapid = 'G0'    # Rapid positioning - do not change this to G00 as G00 is used elsewhere for forcing mode change
         @cmd_arc = 'G02'     # coordinated helical motion about Z axis
         @cmd_arc_rev = 'G03' # counterclockwise helical motion about Z axis
         @output_file_name = output_file_name
         @mill_out_file = nil

         @Limit_up_feed = false           # swarfer: set this to true to use @speed_plung for Z up moves
         #@cw = PhlatScript.usePlungeCW?   # swarfer: spiral cut direction
         @cw = PhlatScript.useOverheadGantry? # if set then do CW conventional inside cut, else CCW

         @tooshorttoramp = 0.02           # length of an edge that is too short to bother ramping, will be calculated
       end
 
      # Sketchup8s version of ruby does not round to more than 0 places
      def round(input,places)
         mult = 10.0 ** places
         input *= mult
         input = input.round
         input = input / mult
         input
      end
      
      # feed the retract depth and tabel zero into this object
      def set_retract_depth(newdepth, tableflag)
         @retract_depth = newdepth
         @table_flag = tableflag
      end

      # feed bit diameter into this object, also calculates tooshorttoramp
      def set_bit_diam(diameter)
         # @curr_bit.diam = diameter
         @bit_diameter = diameter
         @tooshorttoramp = diameter / 2 # do not ramp edges that are less than a bit radius long - also affect optimizer
         @rampdist = diameter * RAMPMULT
      end

      # get too short to ramp value
      attr_reader :tooshorttoramp

      # sketchup compares to 0.001" but that is too coarse, so we do it ourselves to 10 times that  (1.4a)
      def notequal(a, b)
         (a - b).abs > 0.0001
      end
      
      # calculate a new feedrate from the hole and bit diameters, lower limit is 10% and 50mm/min
      # if feed_adjust is true then scale feedrate, else just return the given rate
      def feedScale(diam, feedrate)
         feedratio = (diam - @bit_diameter) / diam
			puts "   diam #{sprintf("%0.3f",diam.to_mm)} feedratio #{sprintf("%0.3f",feedratio)}" if @debug
         if (feedratio <= 0.8) && $phoptions.feed_adjust? # if true then reduce feedrate during arc moves in holes
            result = feedratio > 0.1 ? feedratio * feedrate : 0.1 * feedrate
            if result.to_mm < 50.mm # GRBL lower limit
               result = 50.mm
            end
         else
            result = feedrate
         end 
         result
      end

      # print a cnc statement to the cnc file, multiple args will be separate lines
      def cncPrint(*args)
         if @mill_out_file
            args.each do |string|
               string = string.to_s.sub(/G0 /, 'G00 ') # changing G0 to G00 everywhere else is tricky, just do it here
               @mill_out_file.print(string)
            end
         else
            args.each { |string| print string }
            # print arg
         end
      end

      # returns array of strings of length size or less
      def chunk(string, size)
         string.scan(/.{1,#{size}}/)
      end

      # print a commment using current comment options
      def cncPrintC(string)
         if $phoptions.usecomments? # only output comments if usecomments is true
            string = string.strip.delete("\n")
            string = string.gsub(/\(|\)/, '')
            if string.length > 48
               chunks = chunk(string, 45)
               chunks.each do |bit|
                  bb = PhlatScript.gcomment(bit)
                  cncPrint(bb + "\n")
               end
            else
               string = PhlatScript.gcomment(string)
               cncPrint(string + "\n")
            end
         end
      end

      # strip trailing zeros from the string
      def stripzeros(inp, ignore = false)
         out = inp
         if (@precision > 2) || ignore
            #out = out.gsub(/00$/, '0') while out =~ /00$/ # remove trailing 00
				while ((out =~ /0$/) and (out =~ /\.0$/).nil?) # remove trailing 0 but not .0
				   out = out.gsub(/0$/, '') 
				end
            if !ignore # for normal trims
               if (out =~ /\.0/).nil?
                  # puts "1 " + out               if (@debug)
                  if (out =~ /0$/) != nil
                     out = out.gsub(/0$/, '')
                     # puts "2 " + out            if (@debug)
                  end
               end
            else # if ignore is true, then trim all trailing zeros
               out = out.gsub(/\.0$/, '') if out =~ /\.0$/ # if ends in a .0, remove it
            end
         end
         out
      end

      # format a measurement for output as Gcode
      # * axis will be left stripped
      # * measure will be converted to mm if needed, and formated to @precision
      def format_measure(axis, measure)
         # UI.messagebox("in #{measure}")
         m2 = @is_metric ? measure.to_mm : measure.to_inch
         # UI.messagebox(sprintf("  #{axis}%-10.*f", @precision, m2))
         # UI.messagebox("out mm: #{measure.to_mm} inch: #{measure.to_inch}")
         axis.upcase!
         out = sprintf(" #{axis.lstrip}%-5.*f", @precision, m2)
         # strip trailing 0's to shorten line for GRBL
         sout = stripzeros(out)
			# add .0 back on if it is missing
			if (sout =~ /\./).nil?
			   sout = sout + ".0"
			end
			#puts "#{out} #{sout}"
         sout
      end

      # format a feedrate for output
      # This could output inch feedrates as floats, but gplot chokes on that
      def format_feed(f)
         feed = @is_metric ? f.to_mm : f.to_inch
         sprintf(' F%-4d', feed.to_i)
      end

      # Start the job and output the header info to the cnc file
      # * outputs A B C axis commands if needed
      def job_start(optim, gcodedebug, extra = @extr)
         if @output_file_name
            done = false
            until done
               begin
                  @mill_out_file = File.new(@output_file_name, 'w')
                  done = true
               rescue
                  button_pressed = UI.messagebox 'Exception in PhlatMill.job_start ' + $ERROR_INFO, 5 # , RETRYCANCEL , "title"
                  done = (button_pressed != 4) # 4 = RETRY ; 2 = CANCEL
                  # TODO still need to handle the CANCEL case ie. return success or failure
               end
            end
         end
         #      @bit_diameter = Sketchup.active_model.get_attribute Dict_name, Dict_bit_diameter, Default_bit_diameter
         @bit_diameter = PhlatScript.bitDiameter
         @tooshorttoramp = @bit_diameter / 2
         @rampdist = @bit_diameter * RAMPMULT

         #cncPrint("%\n")
         # do a little jig to prevent the code highlighter getting confused by the bracket constructs
         vs1 = PhlatScript.getString('PhlatboyzGcodeTrailer')
         vs2 = $PhlatScriptExtension.version
         verstr = (vs1 % vs2).to_s + "\n"
         cncPrintC(verstr)
         if PhlatScript.sketchup_file
            fn = PhlatScript.sketchup_file.gsub(/\(|\)/, '-') # remove existing brackets, confuses CNC controllers to have embedded brackets
         else
            fn = 'nonam'
         end
         cncPrintC("File: #{fn}") if PhlatScript.sketchup_file
         cncPrintC("Bit diameter: #{Sketchup.format_length(@bit_diameter)}")
         cncPrintC("Feed rate: #{Sketchup.format_length(@speed_curr)}/min")
         if @speed_curr != @speed_plung
            cncPrintC("Plunge Feed rate: #{Sketchup.format_length(@speed_plung)}/min")
         end
         cncPrintC("Material Thickness: #{Sketchup.format_length(@material_thickness)}")
         cncPrintC("Material length: #{Sketchup.format_length(@material_h)} X width: #{Sketchup.format_length(@material_w)}")
         cutstr = (PhlatScript.useOverheadGantry?) ? "Conventional Cut" : "   Climb Cut"
         cncPrintC("Overhead Gantry: #{PhlatScript.useOverheadGantry?} = #{cutstr}")
         cncPrintC('Retract feed LIMITED to plunge feed rate') if @Limit_up_feed
         if PhlatScript.useMultipass?
            cncPrintC("Multipass enabled, Depth = #{Sketchup.format_length(@multidepth)}")
         end
         if PhlatScript.mustramp?
            if PhlatScript.rampangle == 0
               cncPrintC('RAMPING with no angle limit')
            else
               cncPrintC("RAMPING at #{PhlatScript.rampangle} degrees")
            end
         end

         if @depthfirst
            cncPrintC('Plunge Depth first')
         else
            cncPrintC('Plunge Diam First')
         end

         cncPrintC('Plunge Use reduced safe height OFF') unless $phoptions.use_reduced_safe_height?
         cncPrintC('Plunge Use fuzzy hole OFF') unless $phoptions.use_fuzzy_holes?
         cncPrintC('Plunge Use quarter arcs OFF') unless @quarters
         cncPrintC('Plunge Using Quickpeck') if @quickpeck

         cncPrintC('Using plain toolchange') if $phoptions.toolnum > -1
         if $phoptions.toolfile != 'no'
            cncPrintC("Using toolchange file #{File.basename($phoptions.toolfile)}")
         end

         if optim # swarfer - display optimize status as part of header
            cncPrintC('Optimization is ON')
         else
            cncPrintC('Optimization is OFF')
         end
         if $phoptions.feed_adjust?
            cncPrintC('Arc Feedrate scale is ON')
         end
         if @laser # swarfer - display laser mode status as part of header
            if @laser_grbl_mode
               cncPrintC('LASER for GRBL') unless @laser_power_mode
               cncPrintC('LASER for GRBL PWR') if @laser_power_mode
            else
               @laser_power_mode = false # force off if not in GRBL mode
               cncPrintC('LASER is ON')
            end
         end
         if @servo # servo mode in header
            cncPrintC('Servo pen control mode')
         end

         if extra != '-'
            # puts extra
            extra.split(/\n/).each { |bit| cncPrintC(bit) }
         end

         cncPrintC('www.PhlatBoyz.com')
         PhlatScript.checkParens(@comment, 'Comment')
         # puts @comment
         @comment.split(/\$\//).each { |line| cncPrintC(line) } unless @comment.empty?
         
         cncPrintC("PhlatMill debug is ON") if @debug   
         cncPrintC("GcodeUtil debug is ON") if gcodedebug   

         # adapted from swarfer's metric code
         # metric by SWARFER - this does the basic setting up from the drawing units
         if PhlatScript.isMetric
            unit_cmd = 'G21'
            @precision = 3
            @is_metric = true
         else
            unit_cmd = 'G20'
            @precision = 4
            @is_metric = false
         end

         stop_code = $phoptions.use_exact_path? ? 'G61' : '' # G61 - Exact Path Mode
         ij_code = $phoptions.use_incremental_ij? ? 'G91.1' : '' # G91.1 - set incremental IJ mode
         if @gforce # output the header on separate lines for Marlin
            cncPrint("G90\n#{unit_cmd}\nG49\nG17\n"); # G90 - Absolute programming (type B and C systems)
            cncPrint("#{stop_code}\n") if stop_code != ''
            cncPrint("#{ij_code}\n") if ij_code != ''
            cncPrint(format_feed(@speed_plung).strip) # output an initial feed rate so system always has it defined
            cncPrint("\n")
         else
            cncPrint("G90 #{unit_cmd} G49 G17") # G90 - Absolute programming (type B and C systems)
            cncPrint(" #{stop_code}")   if stop_code != ''
            cncPrint(" #{ij_code}")     if ij_code != ''
            cncPrint(format_feed(@speed_plung)) # output an initial feed rate so system always has it defined
            cncPrint("\n")
         end
         # tool change
         if $phoptions.toolnum > -1
            tool = "T#{$phoptions.toolnum} M06"
            if $phoptions.useg43?
               tool += ' G43'
               if $phoptions.useH?
                  tool += " H#{$phoptions.toolh}" if $phoptions.toolh > -1
               end
            end
            tool += "\n"
            cncPrint(tool)
         else
            if $phoptions.toolfile != 'no'
               lines = IO.readlines($phoptions.toolfile)
               if lines
                  tool = ''
                  lines.each do |line|
                     if !line.match(/%s/)
                        tool += line
                     else # stick in the tooloffset in the %s place
                        li = line.index(/\(|;/) # remove the comment first, just in case it has %s in it
                        line = line[0, li] + "\n" if li > 0
                        line = sprintf(line, format_measure('', $phoptions.tooloffset).strip)
                        tool += line
                     end
                  end
                  cncPrint(tool)
               end
            end
         end

         # output A or B axis rotation if selected
         if !(@laser || @servo)
			   zstr = format_measure('Z', $phoptions.end_z);
            retract($phoptions.end_z,"G53 G0")   #Sep2018 safe raise before initial move to start point
            setZ(@retract_depth * 2)
            @cc = 'G00'
         else
            setZ(@retract_depth * 2)
         end
         if @servo
            cncPrint('M3 S' , @servo_up , "\n")
            @penPos = @servo_up # keep track of actual pen position
            setZ(@retract_depth * 2)
         end
         cncPrint('G00 A', $phoptions.posA.to_s, "\n") if $phoptions.useA?
         cncPrint('G00 B', $phoptions.posB.to_s, "\n") if $phoptions.useB?
         cncPrint('G00 C', $phoptions.posC.to_s, "\n") if $phoptions.useC?
         #cncPrint("G0 X0 Y0\n")
         if !(@laser || @servo)
            cncPrint('M3 S', @spindle_speed, "\n") # M3 - Spindle on (CW rotation)   S spindle speed
         end
      end

      # end the job, output the footer and close the file
      # * Returns A B C to 0 if used
      # * closes file
      def job_finish
         cncPrint("M05\n") # M05 - Spindle off
         if $phoptions.useA? || $phoptions.useB? || $phoptions.useC?
            cncPrint('G00')
            cncPrint(' A0.0') if $phoptions.useA?
            cncPrint(' B0.0') if $phoptions.useB?
            cncPrint(' C0.0') if $phoptions.useC?
            cncPrint("\n")
         end

         cncPrint("M30\n") # M30 - End of program/rewind tape
         #cncPrint("%\n")
         if @mill_out_file
            begin
               @mill_out_file.close
               @mill_out_file = nil
               UI.messagebox('Output file stored: ' + @output_file_name)
            rescue
               UI.messagebox 'Exception in PhlatMill.job_finish ' + $ERROR_INFO
            end
         else
            UI.messagebox('Failed to store output file. (File may be opened by another application.)')
         end
       end

      # Output a generic warning about exceeded limits
      def moveWarning(axis, dest, comp, max)
         cncPrintC("Warning move #{axis}=" + dest.to_l.to_s.sub(/~ /, '') + " #{comp} of " + max.to_l.to_s + "\n")
      end

      # Calculate 'laser brightness' as a percentage of material thickness and output as a proportion of max spindle speed
      # if multipass is on, always use max power as we are probably cutting and scaling the output is not required
      # user can still adjust power by setting max spindle speed
      def laserbright(zo)
         if PhlatScript.useMultipass?
            depth = @spindle_speed
         else
            if @table_flag
               depth = ((@material_thickness - zo) / @material_thickness) * @spindle_speed
            else # zo is negative
               depth = (zo / -@material_thickness) * @spindle_speed
            end
         end
         return depth
      end
      
      # put the pen down in servo_time seconds, assume it is up as servo_up
      # note that the servo will go to (0) when M5 is issued, so this must be a safe penUP position
      # ergo servo_up  < servoDown
      def penDown()
         cncPrintC('penDown')
         if (@penPos == @servo_down)
            return
         end
         if (@servo_time == 0)
            # output 1 move
            cncPrint('M3 S' , @servo_down.to_i, "\n")
            cncPrint('G4 P', sprintf("%0.3f",0.1) , "\n")
            @penPos = @servo_down
            return
         end
         diff = @servo_down - @servo_up
         steps = diff / 8
         if steps < 1
            steps = 1
         end
         step = (diff / steps).to_i
         timestep = @servo_time / steps
         now = @servo_up
         while now < @servo_down
            now += step
            if now > @servo_down
               now = @servo_down
               timestep = 0
            end      
            cncPrint('M3 S' , now.to_i, "\n")
            if timestep > 0
               cncPrint('G4 P', sprintf("%0.3f",timestep) , "\n")
            end
         end
         @penPos = @servo_down   
      end

      # put the pen Up in servo_time seconds, assume it is DOWN as servo_down
      # note that the servo will go to (0) when M5 is issued, so this must be a safe penUP position
      # ergo servo_up  < servoDown
      def penUp()
         cncPrintC('penUp')
         if (@penPos == @servo_up)
            return
         end
         if (@servo_time == 0)
            # output 1 move
            cncPrint('M3 S' , @servo_up.to_i, "\n")
            cncPrint('G4 P', sprintf("%0.3f",0.1) , "\n")
            @penPos = @servo_up
            return
         end
         
         diff = @servo_down - @servo_up
         steps = diff / 8  #steps of 8, servo scaled 0..255
         if steps < 1
            steps = 1
         end
         step = (diff / steps).to_i
         timestep = round(@servo_time / steps, 3)
         puts "timestep " +  timestep.to_s
         now = @servo_down
         while now > @servo_up
            now -= step
            if now < @servo_up
               now = @servo_up
               timestep = 0
            end
            cncPrint('M3 S' , now.to_i, "\n")
            if timestep > 0
               cncPrint('G4 P', sprintf('%0.3f',timestep) , "\n")
            end
         end
         @penPos = @servo_up   
      end

      # Move to xo,yo,zo
      # * only outputs axes that have changed
      # * Obeys @laser
      # * if multipass is on, AND @laser, then every pass will be at 100% power
      def move(xo, yo = @cy, zo = @cz, so = @speed_curr, cmd = @cmd_linear)
         # cncPrint("(move " +sprintf("%6.3f",xo.to_mm)+ ", "+ sprintf("%6.3f",yo.to_mm)+ ", "+ sprintf("%6.3f",zo.to_mm)+", "+ sprintf("feed %6.2f",so)+ ", cmd="+ cmd+")\n")
         #puts "(move ", sprintf("%10.6f",xo), ", ", sprintf("%10.6f",yo), ", ", sprintf("%10.6f",zo),", ", sprintf("feed %10.6f",so), ", cmd=", cmd,")\n" if @debug
         ringonce("move #{zo.to_mm}",caller)         
         if cmd != @cmd_rapid
            if !notequal(@retract_depth, zo)
               cmd = @cmd_rapid
               #            so=0
               @cs = 0
            else
               cmd = @cmd_linear
            end
         end

         # print "( move xo=", xo, " yo=",yo,  " zo=", zo,  " so=", so,")\n"
         if !notequal(xo, @cx) && !notequal(yo, @cy) && !notequal(zo, @cz)
            # print "(move - already positioned)\n"
            @no_move_count += 1
         else
            if xo > @max_x
               # puts "xo big"
               moveWarning('x', xo, 'GT max', @max_x)
               xo = @max_x
            elsif xo < @min_x
               # puts "xo small"
               moveWarning('X', xo, 'LT min', @min_x)
               xo = @min_x
            end

            if yo > @max_y
               # puts "yo big"
               moveWarning('Y', yo, 'GT max', @max_y)
               yo = @max_y
            elsif yo < @min_y
               # puts "yo small"
               moveWarning('Y', yo, 'LT min', @min_y)
               yo = @min_y
            end

            if zo > @max_z
               moveWarning('Z', zo, 'GT max', @max_z)
               zo = @max_z
            elsif zo < @min_z
               moveWarning('Z', zo, 'LT min', @min_z)
               zo = @min_z
            end
            command_out = ''
            command_out += cmd if (cmd != @cc) || @gforce || @laser
            hasz = hasx = hasy = false
            if notequal(xo, @cx)
               command_out += format_measure('X', xo)
               hasx = true
            end
            if notequal(yo, @cy)
               command_out += format_measure('Y', yo)
               hasy = true
            end

            if @laser # then set PWM power if changed
               # calculate 'laser brightness' as a percentage of material thickness
               # if multipass then use full power, else scale to Z depth
               depth = laserbright(zo)
               # insert the pwm command before current move
               if notequal(zo, @cz)
                  lcmd = @laser_power_mode ? 'M04' : 'M03'
                  # cncPrintC("move Z laser")
                  if hasx || hasy
                     command_out = lcmd + ' S' + depth.abs.to_i.to_s + "\n" + command_out
                  else
                     command_out = lcmd + ' S' + depth.abs.to_i.to_s
                     cmd = lcmd
                  end
                  #               @cs = 3.14 #make sure feed rate gets output on next move
               end
            else
               if notequal(zo, @cz)
                  if (@servo)
                     if zo < @cz  # going down
                        penDown()
                        command_out += format_measure('Z',-0.1)
                     else  # going up
                        penUp()
                        command_out += format_measure('Z',0.1)
                     end
                  else
                     hasz = true
                     command_out += format_measure('Z', zo)
                  end
               end
            end

            if !hasx && !hasy && hasz # if only have a Z motion
               if (zo < @cz) || @Limit_up_feed # if going down, or if overridden
                  so = PhlatScript.plungeRate
                  #            cncPrintC("(move only Z, force plungerate)\n")
               end
            end
            #          cncPrintC("(   #{hasx} #{hasy} #{hasz})\n")
            if notequal(so, @cs) && (cmd != @cmd_rapid)
               command_out += format_feed(so)
               @cs = so
            end
            if @pcomment != ''
               command_out += ' ' + PhlatScript.gcomment(@pcomment) if $phoptions.usecomments?
               @pcomment = ''
            end            
            command_out += "\n"
            cncPrint(command_out)
            @cx = xo
            @cy = yo
            @cz = zo
            @cc = cmd
         end
      end

      # Retract Z to the retract height
      # * Obeys @Limit_up_feed
      # * Obeys @laser
      def retract(zo = @retract_depth, cmd = @cmd_rapid)
         #      cncPrintC("(retract ", sprintf("%10.6f",zo), ", cmd=", cmd,")\n")
         ringonce("retract #{zo.to_mm}",caller)
         #      if (zo == nil)
         #        zo = @retract_depth
         #      end
         if !notequal(@cz, zo)
            @no_move_count += 1
         else
            if zo > @max_z
               msg = "(RETRACT limiting Z to @max_z)\n"
               cncPrintC(msg)
               puts msg
               zo = @max_z
            elsif zo < @min_z
               msg = "(RETRACT limiting Z to @min_z)\n"
               cncPrintC(msg)
               puts msg
               zo = @min_z
            end
            command_out = ''
            if @laser
               command_out += 'M05'
               cmd = 'M05' # force output of motion command at next move
            else
               if @servo
                  penUp()
                  command_out += 'G0 Z0.1'
                  cmd = @cmd_rapid
               else
                  if @Limit_up_feed && (cmd == 'G0') && (zo > 0) && (@cz < 0)
                     cncPrintC("(RETRACT G1 to material thickness at plunge rate)\n")
                     command_out += 'G01' + format_measure('Z', 0)
                     command_out += format_feed(@speed_plung)
                     command_out += "\n"
                     @cs = @speed_plung
                     #          G00 to zo
                     command_out += 'G00' + format_measure('Z', zo)
                  else
                     #          cncPrintC("(RETRACT normal #{@cz} to #{zo} )\n")
                     if notequal(zo,@cz)
                        command_out += cmd if (cmd != @cc) || @gforce
                        command_out += format_measure('Z', zo)
                     end
                  end
               end
            end
            if @pcomment != ''
               command_out += ' ' + PhlatScript.gcomment(@pcomment) if $phoptions.usecomments?
               @pcomment = ''
            end
            command_out += "\n"
            cncPrint(command_out)
            @cz = zo
            @cc = cmd
         end
      end

      # Plunge to +zo+ depth
      # * +zo+ is Z level to go to
      # * +so+ is feed speed to use
      # * +cmd+ = default cmd, normally G01
      # * +fast+ = use fastapproach , set to false to force it off
      # * Obeys @laser and @servo
      def plung(zo, so = @speed_plung, cmd = @cmd_linear, fast = true)
         #      cncPrintC("plung "+ sprintf("%10.6f",zo.to_mm)+ ", @cs="+ @cs.to_mm.to_s+ ", so="+ so.to_mm.to_s+ " cmd="+ cmd+"\n")
         ringonce("plung #{zo.to_mm}", caller)
         if !notequal(zo, @cz)
            @no_move_count += 1
            false
         else
            if zo > @max_z
               msg = "(PLUNGE Warning: limiting Z to max_z #{@max_z.to_l})\n"
               cncPrintC(msg)
               puts msg
               zo = @max_z
            elsif zo < @min_z
               msg = "(PLUNGE Warning: limiting Z to min_z #{@min_z.to_l})\n"
               cncPrintC(msg)
               puts msg
               zo = @min_z
            end
            command_out = ''
            if @laser
               # calculate 'laser brightness' as a percentage of material thickness
               depth = laserbright(zo)
               cmd = @laser_power_mode ? 'M04' : 'M03'
               cncPrint(cmd + ' S', depth.abs.to_i, "\n")
               so = 3.14 # make sure feed rate gets output on next move
               cmd = 'm3' # force output of motion commands at next move
            else
               if @servo
                  penDown()
                  command_out += 'G1 Z-0.1'
               else
                  # if above material, G00 to near surface, fastapproach
                  if fast && @fastapproach
                     if !notequal(@cz, @retract_depth) && (zo < @cz)
                        offset = @is_metric ? 0.5.mm : 0.02.inch
                        flag = false
                        if @table_flag
                           if (@material_thickness + offset) < @retract_depth
                              nz = @material_thickness + offset
                              flag = true
                           end
                        else
                           if offset < @retract_depth
                              nz = 0.0 + offset
                              flag = true
                           end
                        end
                        if flag && nz != @cz
                           retract(nz)
                           @cc = @cmd_rapid
                        end
                     end
                  else
                     retract(@retract_depth)  # may do nothing
                  end
                  command_out += cmd if (cmd != @cc) || @gforce
                  command_out += format_measure('Z', zo)
                  so = @speed_plung # force using plunge rate for vertical moves
                  #        sox = @is_metric ? so.to_mm : so.to_inch
                  #        cncPrintC("(plunge rate #{sox})\n")
                  if notequal(so, @cs)
                     command_out += format_feed(so)
                     @cs = so
                  end
               end
            end
            if (command_out != '')
               command_out += "\n"
               cncPrint(command_out)
            end
            @cz = zo
            @cc = cmd
            true
         end
      end

      # Do a ramped move, calls ramplimit() or rampnolimit() as needed
      def ramp(limitangle, op, zo, so = @speed_plung, nodist=false, cmd = @cmd_linear)
         if limitangle > 0
            ramplimit(limitangle, op, zo, so, nodist, cmd)
         else
            rampnolimit(op, zo, so, nodist, cmd)
         end
      end

      # This ramp is limited to limitangle, so it will do multiple ramps to satisfy this angle
      # * We are ramping instead of plunging, ramping along this segment
      # * +limitangle+ - angle limit in degrees
      # * +op+ - the Opposite Point, the other end of the line segment
      # * +zo+ - destination depth
      # * +so+ - feed speed
      # * +nodist+ = true if you want to ignore rampdist, as must be done for single line fold cuts
      def ramplimit(limitangle, op, zo, so = @speed_plung, nodist=false, cmd = @cmd_linear)
         cncPrintC("(ramp limit #{limitangle}deg zo=" + sprintf('%10.6f', zo) + ', so=' + so.to_s + ' cmd=' + cmd + '  op=' + op.to_s.delete('()') + ")\n") if @debugramp
         if !notequal(zo, @cz)
            @no_move_count += 1
         else
            # we are at a point @cx,@cy,@cz and need to ramp to op.x,op.y, limiting angle to rampangle ending at @cx,@cy,zo
            if zo > @max_z
               cncPrintC("(RAMP limiting Z to max_z #{@max_z})\n")
               zo = @max_z
            elsif zo < @min_z
               cncPrintC("(RAMP limiting Z to min_z #{@min_z})\n")
               zo = @min_z
            end

            command_out = ''
            # if above material, G00 to near surface to save time
            unless notequal(@cz, @retract_depth)
               @cz = if @table_flag
                        @material_thickness + 0.2.mm
                     else
                        0.0 + 0.2.mm
                     end
               command_out += 'G00' + format_measure('Z', @cz) + "\n"
               @cc = @cmd_rapid
            end

            # find halfway point
            # is the angle exceeded?
            point1 = Geom::Point3d.new(@cx, @cy, 0) # current point
            point2 = Geom::Point3d.new(op.x, op.y, 0) # the other point
            distance = point1.distance(point2) # this is 'adjacent' edge in the triangle, bz is opposite

            if distance < @tooshorttoramp # dont need to ramp really since not going anywhere far, just plunge
               puts "distance=#{distance.to_mm} < #{@tooshorttoramp.to_mm} so just plunging" if @debugramp
               plung(zo, so, @cmd_linear)
               cncPrintC("ramplimit end, translated to plunge\n")
               @cz = zo
               @cs = so
               @cc = @cmd_linear
               return
            end
            #find a point to ramp to
            bz = ((@cz - zo) / 2).abs # half distance from @cz to zo, not height to cut to
            if (@rampdist < distance) && !nodist
               #find new point
               cncPrintC("ramplimit find new ramp point #{@rampdist.to_mm} #{distance}  #{nodist} ") if @debugramp
               prop = @rampdist / distance # proportion of distance
               rpoint =  Geom::Point3d.linear_combination(1-prop, point1, prop, point2)
               #puts "rpoint #{rpoint} rampdist #{@rampdist} distance #{distance}"
               anglerad = Math.atan(bz / @rampdist)
               rdist = @rampdist
            else
               #use opposite point, always if nodist is true
               cncPrintC("ramplimit use point2 #{@rampdist.to_mm} #{distance} #{nodist} ")  if @debugramp
               rpoint = point2
               anglerad = Math.atan(bz / distance)
               rdist = distance
            end

            angledeg = PhlatScript.todeg(anglerad)
            #puts "angledeg #{angledeg}"
            if angledeg > limitangle # then need to calculate a new bz value
               puts "limit exceeded  #{angledeg} > #{limitangle}  old bz=#{bz}" if @debugramp
               bz = rdist * Math.tan(PhlatScript.torad(limitangle))
               if bz == 0
                  puts "rdist=#{rdist} bz=#{bz}" if @debugramp
                  passes = 4
               else
                  passes = ((zo - @cz) / bz).abs
               end
               puts "   new bz=#{bz.to_mm} passes #{passes}" if @debugramp # should always be even number of passes?
               passes = passes.floor
               passes += if passes.modulo(2).zero?
                            2
                         else
                            1
                         end
               if passes > 100
                  cncPrintC('clamping ramp passes to 100, segment very short')
                  puts 'clamping ramp passes to 100' if @debugramp
                  passes = 100
               end
               bz = (zo - @cz).abs / passes
               puts "   rounded new bz=#{bz.to_mm} passes #{passes}" if @debugramp # now an even number
            else
               puts 'bz is half distance' if @debugramp
               # bz = (zo-@cz)/2 + @cz
            end
            puts "bz=#{bz.to_mm}" if @debugramp

            so = @speed_plung # force using plunge rate for ramp moves

            curdepth = @cz
            cnt = 0
            errmsg = ''
            while (curdepth - zo).abs > 0.0001
               cnt += 1
               if cnt > 1000
                  puts "high count break #{curdepth.to_mm}  #{zo.to_mm}"
                  command_out += "ramp loop high count break, do not cut this code\n"
                  errmsg = 'ramp loop high count break, do not cut this code'
                  break
               end
               puts "curdepth #{curdepth.to_mm}" if @debugramp
               # cut to Xop.x Yop.y Z (zo-@cz)/2 + @cz
               command_out += cmd if (cmd != @cc) || @gforce
               @cc = cmd
               command_out += format_measure('x', rpoint.x)
               command_out += format_measure('y', rpoint.y)
               # for the last pass, make sure we do equal legs - this is mostly circumvented by the passes adjustment
               if (zo - curdepth).abs < (bz * 2)
                  puts 'last pass smaller bz' if @debugramp
                  bz = (zo - curdepth).abs / 2
               end

               curdepth -= bz
               curdepth = zo if curdepth < zo
               command_out += format_measure('z', curdepth)
               command_out += format_feed(so) if notequal(so, @cs)
               @cs = so
               command_out += "\n"

               # cut to @cx,@cy, curdepth
               curdepth -= bz
               curdepth = zo if curdepth < zo
               command_out += cmd if (cmd != @cc) || @gforce
               command_out += format_measure('X', @cx)
               command_out += format_measure('y', @cy)
               command_out += format_measure('z', curdepth)
               command_out += "\n"
            end # while
            UI.messagebox(errmsg) if errmsg != ''

            cncPrint(command_out)
            cncPrintC("(ramplimit end)\n") if @debugramp
            @cz = zo
            @cs = so
            @cc = cmd
         end
      end

      # This ramps down to half the depth at otherpoint (op), and back to cut_depth at start point.
      # * This may end up being quite a steep ramp if the distance is short.
      # * 9/9/2018 limit length of ramp to @rampdist
      # * +nodist+ = true if you want to ignore the @rampdist value
      def rampnolimit(op, zo, so = @speed_plung, nodist=false, cmd = @cmd_linear)
         cncPrintC('(ramp ' + sprintf('%10.6f', zo) + ', so=' + so.to_mm.to_s + ' cmd=' + cmd + '  op=' + op.to_s.delete('()') + ")\n") if @debugramp
         if !notequal(zo, @cz)
            @no_move_count += 1
            #         cncPrintC("rampnolimit no move")
            # puts "nomove zo #{zo} @cz #{@cz}"
         else
            # we are at a point @cx,@cy and need to ramp to op.x,op.y,zo/2 then back to @cx,@cy,zo
            if zo > @max_z
               cncPrintC("(RAMP limiting Z to max_z @max_z)\n")
               zo = @max_z
            elsif zo < @min_z
               cncPrintC("(RAMP limiting Z to min_z @min_z)\n")
               zo = @min_z
            end
            command_out = ''
            # if above material, G00 to surface
            unless notequal(@cz, @retract_depth)
               @cz = if @table_flag
                        @material_thickness + 0.2.mm
                     else
                        0.0 + 0.2.mm
                     end
               command_out += 'G00' + format_measure('Z', @cz) + "\n"
               @cc = @cmd_rapid
            end

            # check the distance
            point1 = Geom::Point3d.new(@cx, @cy, 0) # current point
            point2 = Geom::Point3d.new(op.x, op.y, 0) # the other point
            distance = point1.distance(point2) # this is 'adjacent' edge in the triangle, bz is opposite
            if distance < @tooshorttoramp # dont need to ramp really since not going anywhere far, just plunge
               puts "distance=#{distance.to_mm} so just plunging" if @debugramp
               plung(zo, so, @cmd_linear)
               @cz = zo
               @cs = so
               @cc = @cmd_linear
               cncPrintC("rampnolimit end, plunged\n")
               return
            end
            #find a point to ramp to
            if (@rampdist < distance) && !nodist
               #find new point
               prop = @rampdist / distance # proportion of distance
               rpoint =  Geom::Point3d.linear_combination(1-prop, point1, prop, point2)
               #puts "rpoint #{rpoint} rampdist #{@rampdist} distance #{distance}"
            else
               #use opposite point
               rpoint = point2
            end

            # cut to Xop.x Yop.y Z (zo-@cz)/2 + @cz
            command_out += cmd if (cmd != @cc) || @gforce
            @cc = cmd
            command_out += format_measure('x', rpoint.x)   # go to ramp point
            command_out += format_measure('y', rpoint.y)
            bz = (zo - @cz) / 2 + @cz
            command_out += format_measure('z', bz)
            command_out += format_feed(so) if notequal(so, @cs)
            command_out += "\n"
            # cut to @cx,@cy,zo
            command_out += cmd if (cmd != @cc) || @gforce
            command_out += format_measure('X', @cx)
            command_out += format_measure('y', @cy)
            command_out += format_measure('z', zo)

            command_out += "\n"
            cncPrint(command_out)
            @cz = zo
            @cs = so
            @cc = cmd
         end
      end

      # If you mean the angle that P1 is the vertex of then this should work:
      #    arcos((P12^2 + P13^2 - P23^2) / (2 * P12 * P13))
      # where P12 is the length of the segment from P1 to P2, calculated by
      #    sqrt((P1x - P2x)^2 + (P1y - P2y)^2)

      # Cunning bit of code found online, find the angle between 3 points, in radians
      # * just give it the three points as arrays
      # * p1 is the center point; result is in radians
      def angle_between_points(p0, p1, p2)
         a = (p1[0] - p0[0])**2 + (p1[1] - p0[1])**2
         b = (p1[0] - p2[0])**2 + (p1[1] - p2[1])**2
         c = (p2[0] - p0[0])**2 + (p2[1] - p0[1])**2
         Math.acos((a + b - c) / Math.sqrt(4 * a * b))
      end

      # Arc with Ramp is limited to limitangle, so it will do multiple ramps to satisfy this angle
      # * not going to write an unlimited version, always limited to at most 45 degrees
      # * though some of these arguments are defaulted, they must always all be given by the caller
      def ramplimitArc(limitangle, op, rad, cent, zo, so = @speed_plung, cmd = @cmd_linear)
         if limitangle == 0
            limitangle = 45 # always limit to something
         end
         cncPrintC('ramplimitArc')  if @debugramparc
         cncPrintC("(ramp arc limit #{limitangle}deg zo=" + sprintf('%10.6f', zo) + ', so=' + so.to_s + ' cmd=' + cmd + '  op=' + op.to_s.delete('()') + ")\n") if @debugramparc
         if !notequal(zo, @cz)
            @no_move_count += 1
         else
            # we are at a point @cx,@cy,@cz and need to arcramp to op.x,op.y, limiting angle to rampangle ending at @cx,@cy,zo
            # cmd will be the initial direction, need to reverse for the backtrack
            if zo > @max_z
               cncPrintC("(RAMParc limiting Z to max_z @max_z)\n")
               zo = @max_z
            elsif zo < @min_z
               cncPrintC("(RAMParc limiting Z to min_z @min_z)\n")
               zo = @min_z
            end

            command_out = ''
            # if above material, G00 to near surface to save time
            unless notequal(@cz, @retract_depth)
               @cz = if @table_flag
                        @material_thickness + 0.2.mm
                     else
                        0.0 + 0.2.mm
                     end
               command_out += 'G00' + format_measure('Z', @cz) + "\n"
               cncPrint(command_out)
               @cc = @cmd_rapid
            end

            angle = angle_between_points([@cx, @cy], [cent.x, cent.y], [op.x, op.y])
            arclength = angle * rad
            puts "angle #{angle} arclength #{arclength.to_mm}" if @debugramp
            # with the angle we can find the arc length
            # angle*radius   (radians)

            if cmd.include?('3') # find the 'other' command for the return stroke
               g3 = true
               ocmd = 'G02'
            else
               ocmd = 'G03'
               g3 = false
            end
            # find halfway point
            # is the angle exceeded?
            #         point1 = Geom::Point3d.new(@cx,@cy,0)  # current point
            #         point2 = Geom::Point3d.new(op.x,op.y,0) # the other point
            #         distance = point1.distance(point2)   # this is 'adjacent' edge in the triangle, bz is opposite
            distance = arclength
            if distance < @tooshorttoramp # dont need to ramp really since not going anywhere, just plunge
               puts "arcramp distance=#{distance.to_mm} so just plunging" if @debugramp
               plung(zo, so, @cmd_linear)
               cncPrintC("ramplimitarc end, translated to plunge\n")
               return
            end

            bz = ((@cz - zo) / 2).abs # half distance from @cz to zo, not height to cut to

            anglerad = Math.atan(bz / distance)
            angledeg = PhlatScript.todeg(anglerad)

            if angledeg > limitangle # then need to calculate a new bz value
               puts "arcramp limit exceeded  #{angledeg} > #{limitangle}  old bz=#{bz}" if @debugramp
               bz = distance * Math.tan(PhlatScript.torad(limitangle))
               if bz == 0
                  puts "distance=#{distance} bz=#{bz}" if @debugramp
                  passes = 4
               else
                  passes = ((zo - @cz) / bz).abs
               end
               puts "   new bz=#{bz.to_mm} passes #{passes}" if @debugramp # should always be even number of passes?
               passes = passes.floor
               passes += if passes.modulo(2).zero?
                            2
                         else
                            1
                         end
               bz = (zo - @cz).abs / passes
               puts "   rounded new bz=#{bz.to_mm} passes #{passes}" if @debugramp # now an even number
            else
               puts 'bz is half distance'          if @debugramp
               # bz = (zo-@cz)/2 + @cz
            end
            puts "bz=#{bz.to_mm}" if @debugramp

            so = @speed_plung # force using plunge rate for ramp moves

            curdepth = @cz
            cnt = 0
            command_out = ''
            #         @precision += 1
            cx = @cx
            cy = @cy
            gforcewas = @gforce
            @gforce = true # must have arc commands on every line
            while (curdepth - zo).abs > 0.0001
               # command_out += cmd
               cnt += 1
               if cnt > 1000
                  puts 'ramp arc high count break'
                  command_out += "ramp arc loop high count break, do not cut this code\n"
                  break
               end
               puts "   curdepth #{curdepth.to_mm}" if @debugramp
               # cut to Xop.x Yop.y Z (zo-@cz)/2 + @cz
               #            command_out += format_measure('x',op.x)
               #            command_out += format_measure('y',op.y)
               # for the last pass, make sure we do equal legs - this is mostly circumvented by the passes adjustment
               if (zo - curdepth).abs < (bz * 2)
                  puts '   last pass smaller bz' if @debugramp
                  bz = (zo - curdepth).abs / 2
               end

               curdepth -= bz
               curdepth = zo if curdepth < zo
               #           command_out += format_measure('z',curdepth)
               #           command_out += format_measure('r',rad)
               #           command_out += (format_feed(so))       if notequal(so, @cs)
               command_out += arcmoveij(op.x, op.y, cent.x, cent.y, rad, g3, curdepth, so, cmd, false)
               @cx = op.x # next arcmoveij needs these
               @cy = op.y
               @cz = curdepth
               @cs = so
               #            command_out += "\n";

               # cut to @cx,@cy, curdepth
               curdepth -= bz
               curdepth = zo if curdepth < zo
               #            command_out += ocmd
               #            command_out += format_measure('X',@cx)
               #            command_out += format_measure('Y',@cy)
               #            command_out += format_measure('Z',curdepth)
               #            command_out += format_measure('R',rad)
               #            command_out += "\n"
               ng3 = !g3
               command_out += arcmoveij(cx, cy, cent.x, cent.y, rad, ng3, curdepth, so, ocmd, false)
               @cx = cx # next arcmoveij needs these
               @cy = cy
               @cz = curdepth
            end # while
            @gforce = gforcewas
            #         @precision -= 1
            cncPrint(command_out)
            cncPrintC("(ramplimitarc end)\n") if @debugramp
            @cz = zo
            @cs = so
            @cc = ocmd # ocmd is the last command output
         end
      end

      # Generate code for a spiral bore and return the command string
      # * if ramping is on, lead angle will be limited to rampangle
      # * sh = safeheight, where @cz is now, usually
      # * +xo+ - x position
      # * +yo+ - y position
      # * +zstart+ - z start depth, will rapid to 0.5mm above this before cut
      # * +zend+ - Z end depth
      # * +yoff+ - radius of spiral
      def SpiralAt(xo, yo, zstart, zend, yoff)
         @precision += 1
         cwstr = @cw ? 'CW' : 'CCW'
         cmd =   @cw ? 'G02' : 'G03'
         command_out = ''
         command_out += "   (SPIRAL #{xo.to_mm},#{yo.to_mm},#{(zstart - zend).to_mm},#{yoff.to_mm},#{cwstr})\n" if @debugramp
         command_out += 'G00' + format_measure('X', xo)
         command_out +=         format_measure('Y', yo - yoff) + "\n"
         if @cz != (zstart + 0.5.mm)
            command_out += 'G00' if @gforce
            command_out += '   ' unless @gforce
            command_out += format_measure('Z', zstart + 0.5.mm) + "\n" # rapid to near surface if not already there
         end

         command_out += 'G01' + format_measure('Z', zstart + 0.02.mm) # feed to surface
         feed = @speed_plung
         command_out += format_feed(feed) # always feed at plunge rate
         command_out += "\n"
         # if ramping with limit use plunge feed rate
         @cs = PhlatScript.mustramp? && (PhlatScript.rampangle > 0) ? @speed_plung : @speed_curr

         # // now output spiral cut
         # //G02 X10 Y18.5 Z-3 I0 J1.5 F100
         if PhlatScript.mustramp? && (PhlatScript.rampangle > 0)
            # calculate step for this diameter
            # calculate lead for this angle spiral
            circ = Math::PI * yoff.abs * 2 # yoff is radius
            step = -Math.tan(PhlatScript.torad(PhlatScript.rampangle)) * circ
            puts "(SpiralAt z step = #{step.to_mm} for ramp circ #{circ.to_mm}" if @debugramp
            # now limit it to multipass depth or half bitdiam because it can get pretty steep for small diameters
            if PhlatScript.useMultipass?
               if step.abs > PhlatScript.multipassDepth
                  step = -PhlatScript.multipassDepth
                  step = StepFromMpass(zstart, zend, step)
                  puts " step #{step.to_mm} limited to multipass" if @debugramp
               end
            else
               if step.abs > (@bit_diameter / 2)
                  #               s = ((zstart-zend) / (@bit_diameter/2)).ceil #;  // each spiral Z feed will be bit diameter/2 or slightly less
                  #               step = -(zstart-zend) / s
                  step = StepFromBit(zstart, zend)
                  puts " step #{step.to_mm} limited to fuzzybitdiam/2" if @debugramp
               end
            end
         else
            if PhlatScript.useMultipass?
               step = -PhlatScript.multipassDepth
               step = StepFromMpass(zstart, zend, step)
            else
               #            s = ((zstart-zend) / (@bit_diameter/2)).ceil #;  // each spiral Z feed will be bit diameter/2 or slightly less
               #            step = -(zstart-zend) / s     # ensures every step down is the same size
               step = StepFromBit(zstart, zend)
            end
         end
         mpass = -step
         d = zstart - zend
         puts("Spiralat: step #{step.to_mm} zstart #{zstart.to_mm} zend #{zend.to_mm}  depth #{d.to_mm}") if @debug
         command_out += "   (Z step #{step.to_mm})\n" if @debug
         now = zstart
         while now > zend
            now += step
            if now < zend
               now = zend
            else
               df = zend - now # must prevent this missing the last spiral on small mpass depths, ie when mpass < bit/8
               if df.abs < 0.001 # make sure we do not repeat the last pass
                  now = zend
               else
                  if df.abs < (mpass / 4)
                     if df < 0
                        command_out += "   (SpiralAt: forced depth as very close now #{now.to_mm} zend #{zend.to_mm}" if @debug
                        command_out += format_measure('df', df) + ")\n" if @debug
                        now = zend
                     end
                  end
               end
            end
            command_out += "#{cmd} "
            command_out += format_measure('X', xo)
            command_out += format_measure('Y', yo - yoff)
            command_out += format_measure('Z', now)
            command_out += ' I0'
            command_out += format_measure('J', yoff)
            if feed != @cs
               command_out += format_feed(@cs)
               feed = @cs
            end
            command_out += "\n"
         end # while
         # now the bottom needs to be flat at $depth
         command_out += "#{cmd} "
         command_out += format_measure('X', xo)
         command_out += format_measure('Y', yo - yoff)
         command_out += ' I0.0'
         command_out += format_measure('J', yoff)
         command_out += "\n"
         command_out += "   (SPIRAL END)\n" if @debug
         @precision -= 1
         command_out
       end # SpiralAt

      # Calculate a Z step size based on the bit_diameter , round down
      def StepFromBit(zstart, zend)
         s = ((zstart - zend) / (@bit_diameter / 2)).ceil # ;  // each spiral Z feed will be bit diameter/2 or slightly less
         step = -(zstart - zend) / s
      end

      # Calculate a Z step based on .multipassDepth
      def StepFromMpass(zstart, zend, step)
         c = (zstart - zend) / PhlatScript.multipassDepth # how many passes will it take
         if ((c % 1) > 0.01) && ((c % 1) < 0.5) # if a partial pass, and less than 50% of a pass, then scale step smaller
            c = c.ceil
            step = -(zstart - zend) / c
         end
         step
      end

      # Generate code for a spiral bore and return the command string, using quadrants.
      # * if ramping is on, lead angle will be limited to rampangle
      # * Gplot does not display arcs nicely, by using quadrants we can at least see where the circles are. (since fixed)
      def SpiralAtQ(xo, yo, zstart, zend, yoff)
         #   @debugramp = true
         @precision += 1
         cwstr = @cw ? 'CW' : 'CCW'
         cmd =   @cw ? 'G02' : 'G03'
         finaldiam = 2 * yoff + @bit_diameter
         command_out = ''
         command_out += "   (SPIRALQ #{sprintf('X%0.2f', xo.to_mm)},#{sprintf('Y%0.2f', yo.to_mm)},#{sprintf('depth %0.2f', (zstart - zend).to_mm)},#{sprintf('yoff %0.2f', yoff.to_mm)}, #{sprintf('finaldiam %0.3f',finaldiam.to_mm)} #{cwstr})\n" if @debug
         # have to do X again to have the extra precision we are now using
         command_out += 'G00' + format_measure('X', xo)
         command_out +=         format_measure('Y', yo - yoff) + "\n"
         if @cz != (zstart + 0.5.mm)
            puts "cz #{@cz} zstart #{zstart}" if @debug
            command_out += 'G00' if @gforce
            command_out += '   ' unless @gforce
            command_out += format_measure('Z', zstart + 0.5.mm) + "\n" # rapid to near surface
         end
         command_out += 'G01' + format_measure('Z', zstart + 0.02.mm) # feed to surface
         # from Haas tips 22 May 2020 - for small holes reduce feedrate
         feed = feedScale(finaldiam, @speed_plung)
         command_out += format_feed(feed) # always feed at set feed rate
         command_out += "\n"
         # if ramping with limit use plunge feed rate
         #@cs = PhlatScript.mustramp? && (PhlatScript.rampangle > 0) ? @speed_plung : @speed_curr
         @cs = feed

         # // now output spiral cut
         # //G02 X10 Y18.5 Z-3 I0 J1.5 F100
         if PhlatScript.mustramp? && (PhlatScript.rampangle > 0)
            # calculate step for this diameter
            # calculate lead for this angle spiral
            circ = Math::PI * yoff.abs * 2 # yoff is radius
            step = -Math.tan(PhlatScript.torad(PhlatScript.rampangle)) * circ
            puts "(SpiralAtQ z step = #{step.to_mm} for ramp circ #{circ.to_mm}" if @debugramp
            # now limit it to multipass depth or half bitdiam because it can get pretty steep for small diameters
            if PhlatScript.useMultipass?
               if step.abs > PhlatScript.multipassDepth
                  step = -PhlatScript.multipassDepth
                  step = StepFromMpass(zstart, zend, step)
                  puts " ramp step #{step.to_mm} limited to multipass" if @debugramp
               end
            else
               if step.abs > (@bit_diameter / 2)
                  #            s = ((zstart-zend) / (@bit_diameter/2)).ceil
                  #            step = -(zstart-zend) / s
                  step = StepFromBit(zstart, zend) # each spiral Z feed will be bit diameter/2 or slightly less
                  puts " ramp step #{step.to_mm} limited to fuzzybitdiam/2" if @debugramp
               end
            end
         else
            if PhlatScript.useMultipass?
               step = -PhlatScript.multipassDepth
               command_out += "(step from mpass was #{step.to_mm}" if @debug
               step = StepFromMpass(zstart, zend, step) # possibly recalculate step to have equal sized steps
               command_out += "   became #{step.to_mm})\n" if @debug
            else
               command_out += '(step from bit' if @debug
               step = StepFromBit(zstart, zend) # each spiral Z feed will be bit diameter/2 or slightly less
               command_out += " became #{step.to_mm})\n" if @debug
            end
         end
         mpass = -step
         d = zstart - zend
         puts("SpiralatQ: zstep #{step.to_mm} zstart #{zstart.to_mm} zend #{zend.to_mm}  depth #{d.to_mm}") if @debug
         command_out += "   (Z step #{sprintf('%0.3f', step.to_mm)})\n" if @debug
         now = zstart
         prevz = now
         while now > zend
            now += step # step is negative!
            if now < zend
               now = zend
            else
               df = zend - now # must prevent this missing the last spiral on small mpass depths, ie when mpass < bit/8
               if df.abs < 0.001 # make sure we do not repeat the last pass
                  now = zend
               else
                  if df.abs < (mpass / 4)
                     if df < 0 # sign is important
                        command_out += "   (SpiralAt: forced depth as very close now #{now.to_mm} zend #{zend.to_mm}" if @debug
                        command_out += format_measure('df', df) + ")\n" if @debug
                        now = zend
                     end
                  end
               end
            end
            zdiff = (prevz - now) / 4 # how much to feed on each quarter circle
            #         command_out += "   (Z diff #{zdiff.to_mm})\n"          if @debug

            if @cw
               # x-o y I0 Jo
               command_out += cmd.to_s
               command_out += format_measure('X', xo - yoff) + format_measure(' Y', yo)
               command_out += format_measure('Z', prevz - zdiff)
               command_out += ' I0' + format_measure(' J', yoff)
               if feed != @cs
                  command_out += format_feed(@cs)
                  feed = @cs
               end
               command_out += "\n"
               # x y+O IOf J0
               command_out += cmd.to_s
               command_out += format_measure('X', xo) + format_measure(' Y', yo + yoff)
               command_out += format_measure('Z', prevz - (zdiff * 2))
               command_out += format_measure('I', yoff) + format_measure(' J', 0)
               command_out += "\n"
               # x+of Y I0 J-of
               command_out += cmd.to_s
               command_out += format_measure('X', xo + yoff) + format_measure(' Y', yo)
               command_out += format_measure('Z', prevz - (zdiff * 3))
               command_out += format_measure('I', 0) + format_measure(' J', -yoff)
               command_out += "\n"
               # x Y-of I-of J0
               command_out += cmd.to_s
               command_out += format_measure('X', xo) + format_measure(' Y', yo - yoff)
               command_out += format_measure('Z', prevz - (zdiff * 4))
               command_out += format_measure('I', -yoff) + format_measure(' J', 0)
               command_out += "\n"
            else
               # x+of Y  I0 Jof
               command_out += cmd.to_s
               command_out += format_measure('X', xo + yoff) + format_measure(' Y', yo)
               command_out += format_measure('Z', prevz - zdiff)
               command_out += format_measure('I', 0) + format_measure(' J', yoff)
               if feed != @cs
                  command_out += format_feed(@cs)
                  feed = @cs
               end
               command_out += "\n"
               # x Yof   I-of  J0
               command_out += cmd.to_s
               command_out += format_measure('X', xo) + format_measure(' Y', yo + yoff)
               command_out += format_measure('Z', prevz - zdiff * 2)
               command_out += format_measure('I', -yoff) + format_measure(' J', 0)
               command_out += "\n"
               # X-of  Y  I0    J-of
               command_out += cmd.to_s
               command_out += format_measure('X', xo - yoff) + format_measure(' Y', yo)
               command_out += format_measure('Z', prevz - zdiff * 3)
               command_out += format_measure('I', 0) + format_measure(' J', -yoff)
               command_out += "\n"
               # X  Y-of  Iof   J0
               command_out += cmd.to_s
               command_out += format_measure('X', xo) + format_measure(' Y', yo - yoff)
               command_out += format_measure('Z', now) # prevz - zdiff*4)
               command_out += format_measure('I', yoff) + format_measure(' J', 0)
               command_out += "\n"
            end
            prevz = now
         end # while
         # now the bottom needs to be flat at $depth
         command_out += "(flatten bottom)\n" if @debug
         if @cw
            # x-o y I0 Jo
            command_out += cmd.to_s
            command_out += format_measure('X', xo - yoff) + format_measure('Y', yo) + ' I0' + format_measure('J', yoff)
            command_out += "\n"
            # x y+O IOf J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo + yoff) + format_measure('I', yoff) + format_measure('J', 0)
            command_out += "\n"
            # x+of Y I0 J-of
            command_out += cmd.to_s
            command_out += format_measure('X', xo + yoff) + format_measure('Y', yo) + format_measure(' I', 0) + format_measure('J', -yoff)
            command_out += "\n"
            # x Y-of I-of J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo - yoff) + format_measure('I', -yoff) + format_measure('J', 0)
            command_out += "\n"
         else
            # x+of Y  I0 Jof
            command_out += cmd.to_s
            command_out += format_measure('X', xo + yoff) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', yoff)
            command_out += "\n"
            # x Yof   I-of  J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo + yoff) + format_measure('I', -yoff) + format_measure('J', 0)
            command_out += "\n"
            # X-of  Y  I0    J-of
            command_out += cmd.to_s
            command_out += format_measure('X', xo - yoff) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', -yoff)
            command_out += "\n"
            # X  Y-of  Iof   J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo - yoff) + format_measure('I', yoff) + format_measure('J', 0)
            command_out += "\n"
            #
            #             # 8 point circle, yoff is radius
            #             xx = Math::cos(PhlatScript.torad(45)) * yoff  # offsets to intermediate points
            #             yy = Math::sin(PhlatScript.torad(45)) * yoff
            #
            #             command_out += "g01 " + format_measure("X",xo) + format_measure("Y",yo-yoff) + "\n"
            #
            #             #at x, y-yoff
            #             #2 move to x+xx, y-yy,0,-yoff
            #             command_out += "(to 2)\n"
            #             command_out += "#{cmd}"
            #             x = xo + xx
            #             y = yo - yy
            #             i = 0
            #             j = yoff
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #3 moveto x+yoff,y, -xx, yy
            #             command_out += "(to 3)\n"
            #             command_out += "#{cmd}"
            #             x = xo + yoff
            #             y = yo
            #             i = -xx
            #             j = yy
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #4 moveto x+xx y+yy, -yoff. 0
            #             command_out += "#{cmd}"
            #             x = xo + xx
            #             y = yo + yy
            #             i = -yoff
            #             j = 0
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #5 moveto x, y+yoff,-xx,-yy
            #             command_out += "#{cmd}"
            #             x = xo
            #             y = yo + yoff
            #             i = -xx
            #             j = -yy
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #6 moveto x-xx, y+yy, 0, -yoff
            #             command_out += "#{cmd}"
            #             x = xo - xx
            #             y = yo + yy
            #             i = 0
            #             j = -yoff
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #7 moveto x-yoff, y, xx, -yy
            #             command_out += "#{cmd}"
            #             x = xo - yoff
            #             y = yo
            #             i = xx
            #             j = -yy
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #8 moveto x-xx, y-yy, xx, 0
            #             command_out += "#{cmd}"
            #             x = xo - xx
            #             y = yo - yy
            #             i = yoff
            #             j = 0
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
            #
            #             #1 moveto x y-yoff, xx, yy
            #             command_out += "#{cmd}"
            #             x = xo
            #             y = yo -yoff
            #             i = xx
            #             j = yy
            #             command_out += format_measure("X",x) + format_measure("Y",y) + format_measure("I",i)  + format_measure("J",j)
            #             command_out += "\n"
         end
         command_out += "   (SPIRALatQ END)\n" if @debug
         @precision -= 1
         #   @debugramp = false
         command_out
       end # SpiralAtQ

      # Generate code for a spiral bore and return the command string, using quadrants.
      # This one does center out to diameter, an outward spiral at zo depth.
      # Must give it the final yoff, call it after doing the initial 2D bore.
      # If cboreinner > 0 then use that for starting diam.
      # mod 10 may 2019 to obey CW/CCW direction settings from overheadgantry?
      # Will set feed to speed_curr
      # * +xo+ - X center
      # * +yo+ - Y center
      
      # * +yoff+ - offset to final Y destination value (effective radius)
      # * +ystep+ - stepover for each full turn
      def SpiralOut(xo, yo, zstart, zend, yoff, ystep)
         # @debugramp = true
         puts "spiralout start #{yoff.to_mm}" if @debug
         @precision += 1
         cwstr = @cw ? 'CW' : 'CCW';
         cmd =   @cw ? 'G02': 'G03';
         command_out = ''
         command_out += "   (SPIRALOUT #{sprintf('%0.2f',xo.to_mm)},#{sprintf('%0.2f',yo.to_mm)},#{sprintf('%0.2f',(zstart - zend).to_mm)},#{sprintf('%0.2f',yoff.to_mm)},#{cwstr})\n" if @debugramp

         # cutpoint is 1/2 bit out from the center, at zend depth

         #      command_out += "G00" + format_measure("Y",yo-yoff) + "\n"
         #      command_out += "   " + format_measure("Z",zstart+0.5.mm) + "\n"   # rapid to near surface
         #      command_out += "G01" + format_measure("Z",zstart) # feed to surface
         #      command_out += format_feed(@speed_curr)    if (@speed_curr != @cs)
         #      command_out += "\n"

         # we are at zend depth
         # we need to spiral out to yoff
         yfinal = yo - yoff
         if @cboreinner > 0
            ynow = (@cboreinner / 2 - @bit_diameter / 2)
            command_out += "   (SO ynow offset #{sprintf('%0.2f',ynow.to_mm)})\n" if @debug
            ynow = yo - ynow
            command_out += "   (SO ynow        #{sprintf('%0.2f',ynow.to_mm)})\n" if @debug
         else
            ynow = yo - @bit_diameter / 2
         end
         command_out += "   (SpiralOut  yo #{sprintf('%0.2f',yo.to_mm)} yfinal #{sprintf('%0.2f',yfinal.to_mm)} ynow #{sprintf('%0.2f',ynow.to_mm)} ystep #{sprintf('%0.2f',ystep.to_mm)})\n" if @debug
         cnt = 0

         diamfinal = (yo - yoff) * 2 + @bit_diameter

         while (ynow - yfinal).abs > 0.0001
            # spiral from ynow to ynow-ystep
            yother = yo + (yo - ynow) + ystep / 2
            command_out += "   (SO ynow #{sprintf('%0.2f',ynow.to_mm)}    yother #{sprintf('%0.2f',yother.to_mm)})\n" if @debug
            ynew = ynow - ystep
            if ynew < (yo - yoff)
               command_out += "   (SO ynew clamped)\n" if @debug
               # puts "ynew clamped"                 if @debug
               ynew = yo - yoff
            end
            diam1 = yother - ynow + @bit_diameter
            diam2 = yother - ynew + @bit_diameter
            diam3 = (yo - ynew) * 2 + @bit_diameter
            feed1 = feedScale(diam1, @speed_curr)
            feed2 = feedScale(diam2, @speed_curr)
            feed3 = feedScale(diam3, @speed_curr)
            #puts "diam1 #{diam1.to_mm} diam2 #{diam2.to_mm} feed1 #{feed1.to_mm} feed2 #{feed2.to_mm} feed3 #{feed3.to_mm}"
            
            # R format - cuts correctly but does not display correctly in OpenSCAM, nor Gplot
            #         command_out += 'G03' + format_measure('Y',yother) + format_measure('R', (yother-ynow)/2) +"\n"
            #         command_out += 'G03' + format_measure('Y',ynew) + format_measure('R', (yother-ynew)/2 ) +"\n"
            # IJ format - displays correctly in OpenSCAM, not Gplot
            # first half
            command_out += cmd + format_measure('Y', yother) + ' I0' + format_measure('J', (yother - ynow) / 2)
            if feed1 != @cs
               command_out += format_feed(feed1)
               @cs = feed1
            end
            command_out += "\n"
            # 2nd half
            command_out += cmd + format_measure('Y', ynew) + ' I0' + format_measure('J', -(yother - ynew) / 2)
            if feed2 != @cs
               @cs = feed2
               command_out += format_feed(feed2) 
            end
            command_out += "\n"
            
            ynow -= ystep
            if ynow < (yo - yoff)
               command_out += "   (SO ynow clamped)\n" if @debug
               ynow = yo - yoff
            end
            cnt += 1
            next unless cnt > 1000
            puts 'SpiralOut high count break'
            cncPrint('Error: spiralout high count break')
            break
         end
         command_out += "   (SO final ynow #{sprintf('%0.2f',ynow.to_mm)})\n" if @debug
         #puts "DIAM1 #{diam1.to_mm} diam2 #{diam2.to_mm} feed1 #{feed1.to_mm} feed2 #{feed2.to_mm} feed3 #{feed3.to_mm}"
         # in the case where the loop does nothing we need to calculate feed3
         if cnt == 0
            puts "calc feed3" if @debug
            diam3 = (yo - yoff) * 2 + @bit_diameter
            feed3 = feedScale(diam3, @speed_curr)
            #puts "feed3 #{feed3}"
         end

         @cs = feed3

         # now make it full diameter
         if @cw
            #command_out += "(CW)\n"
            # X-of  Y  I0    J+of
            command_out += cmd.to_s
            command_out += format_measure('X', xo - yoff) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', +yoff)
            command_out += format_feed(feed3) 
            command_out += "\n"
            # x Yof   I+of  J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo + yoff) + format_measure('I', yoff) + format_measure('J', 0)
            command_out += "\n"
            # x+of Y  I0 -Jof
            command_out += cmd.to_s
            command_out += format_measure('X', xo + yoff) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', -yoff)
            command_out += "\n"
            # X  Y-of  I-of   J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo - yoff) + format_measure('I', -yoff) + format_measure('J', 0)
            command_out += "\n"
         else
            # x+of Y  I0 Jof
            #command_out += "(CCW)\n"
            command_out += cmd.to_s
            command_out += format_measure('X', xo + yoff) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', yoff)
            command_out += format_feed(feed3) 
            command_out += "\n"
            # x Yof   I-of  J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo + yoff) + format_measure('I', -yoff) + format_measure('J', 0)
            command_out += "\n"
            # X-of  Y  I0    J-of
            command_out += cmd.to_s
            command_out += format_measure('X', xo - yoff) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', -yoff)
            command_out += "\n"
            # X  Y-of  Iof   J0
            command_out += cmd.to_s
            command_out += format_measure('X', xo) + format_measure('Y', yo - yoff) + format_measure('I', yoff) + format_measure('J', 0)
            command_out += "\n"
         end
         @cc = cmd
         command_out += "   (SPIRALOUT END)\n" if @debug
         @precision -= 1
         # @debugramp = false
         puts "spiralout end" if @debug
         command_out
      end # SpiralOut

      # Calculate a step that gives an exact number of steps
      # * take the existing diam and ystep and possibly modify the ystep to get an exact number of steps
      # * if stepover is 50% then do nothing
      # * if ystep will use up all the remainder space, do not change
      # * if stepover < 50 then make ystep smaller
      # * if stepover > 50% make ystep larger
      # * if cboreinner is > 0 AND > 2D, then start there instead of 2D
      def GetFuzzyYstep(diam, ystep, mustramp, force)
         was = @debug
         @debugc = ''
         @debugc += "(GetFuzzyYstep #{sprintf('%0.3f',diam.to_mm)}, #{sprintf('%0.3f',ystep.to_mm)}, #{mustramp}, #{force})\n" if @debug
         @debug = false
         if mustramp
            if (@cboreinner > 0) && (@cboreinner >= (@bit_diameter * 2))
               @debugc += "(   getfuzzyYstep using cboreinner #{@cboreinner.to_mm})\n" if @debug
               rem = (diam / 2) - (@cboreinner / 2) # still to be cut, we have already cut a @cboreinner hole
               @debugc += "(   getfuzzystep inner rem = #{rem.to_mm})\n" if @debug
            else
               rem = (diam / 2) - @bit_diameter # still to be cut, we have already cut a 2*bit hole
               @debugc += "(   getfuzzystep Rem = #{rem.to_mm})\n" if @debug
            end
         else
            rem = (diam / 2) - (@bit_diameter / 2) # have drilled a bit diam hole
         end
         temp = rem / ystep # number of steps to do it
         @debugc += "(   getfuzzystep diam #{diam.to_mm} temp steps = #{temp}  ystep old #{ystep.to_mm} remainder #{rem.to_mm})\n" if @debug
         if temp < 1.0
            @debugc += '(   getfuzzystep   not going to bother making it smaller)\n' if @debug
            if ystep > rem
               ystep = rem
               @debugc += '(   getfuzzystep    ystep set to remainder)\n' if @debug
            end
            @debug = was
            return ystep
         end
         oldystep = ystep
         flag = false
         if (PhlatScript.stepover < 50) || force # round temp up to create more steps-
            temp = (temp + 0.5).round
            flag = true
         else
            if PhlatScript.stepover > 50            # round temp down to create fewer steps
               temp = (temp - 0.5).round
               flag = true
            else
               if force
                  temp = (temp + 0.5).round
                  flag = true
               end
            end
         end
         if flag                                    # only adjust if we need to
            temp = temp < 1 ? 1 : temp
            @debugc += "(   getfuzzystep   new temp steps = #{temp})\n" if @debug
            #   calc new ystep
            ystep = rem / temp

            if ystep > @bit_diameter # limit to stepover
               if force
                  while ystep > @bit_diameter
                     temp += 1
                     ystep = rem / temp
                     @debugc += "(   getfuzzystep    ystep was > bit, recalculated with force #{temp})\n" if @debug
                  end
               else
                  ystep = PhlatScript.stepover * @bit_diameter / 100
                  @debugc += "(   getfuzzystep    ystep was > bit, limited to stepover)\n" if @debug
               end

            end
            @debugc += "(   getfuzzystep ystep new #{ystep.to_mm})\n" if @debug
            if oldystep != ystep
               @debugc += "(   OLD STEP #{oldystep.to_mm} new step #{ystep.to_mm})\n" if @debug
            end
         end
         if ystep > rem
            @debugc += '(   ystep > rem, trimming to rem)\n' if @debug
            ystep = rem
         end
         @debug = was
         ystep
      end

         # do a plunge hole for laser engraving
         # should have a laseron() and laseroff() call, and a parameter for the delay
         # === 2 modes
         # [non GRBL]
         #    just make a burnt spot,unless large hole then draw circle
         #    laser_dwell must be output as seconds, can be float
         #    laser_dwell is stored as microseconds in the options
         # [GRBL mode]
         #    GRBL v1.1 will have a mode where laser output is prevented unless a G1/2/3 is in motion, thus
         #    a plain spot will not be possible.   Instead, draw a small circle, scale power by depth?
      #    * If grlb_power_mode is true then the spindle enable command M4 is used.  This enables
      #      GRBL 1.1 to scale the laser power during acceleration.
      #
      # for large holes, always draw a circle of the given size.
      def plungelaser(xo, yo, _zStart, zo, diam)
         depth = laserbright(zo) # calculate laser brightness as function of depth
         if @laser_grbl_mode || notequal(diam, @bit_diameter)
            radius = 0.1.mm
            if notequal(diam, @bit_diameter)
               radius = diam / 2.0
               cncPrintC("plungelaser #{diam}")
            else
               cncPrintC('plungelaser')
            end

            out = 'G0' + format_measure('X', xo + radius) + "\n"
            cmd = @laser_power_mode ? 'M04' : 'M03'

            out += "#{cmd} S" + depth.to_i.to_s + "\n" # must have a spindle speed since it may not have been set before this
            if !notequal(radius, 0.1.mm)
               # draw a tiny circle....
               out += 'G2' + format_measure('X', xo + radius) + format_measure('I', -radius) + format_measure('J', 0) # full circle
               if notequal(@speed_curr, @cs)
                  out += format_feed(@speed_curr)
                  @cs = @speed_curr
               end
               out += "\n"
               # out += 'G2' + format_measure('X',xo+radius)  + format_measure('I', radius )  + "\n"
            else # draw a 4 sector large circle
               out += 'G2' + format_measure('X', xo) + format_measure('Y', yo - radius) + format_measure('I', -radius) + format_measure('J', 0)
               if notequal(@speed_curr, @cs)
                  out += format_feed(@speed_curr)
                  @cs = @speed_curr
               end
               out += "\n"
               out += 'G2' + format_measure('X', xo - radius) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', radius)  + "\n"
               out += 'G2' + format_measure('X', xo) + format_measure('Y', yo + radius) + format_measure('I', radius) + format_measure('J', 0)  + "\n"
               out += 'G2' + format_measure('X', xo + radius) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', -radius) + "\n"
            end
            out += "M05\n"
            @cc = 'M5'
         else
            cncPrintC("plungelaser spot #{diam}")
            out = 'M3 S' + depth.to_i.to_s + "\n"
            dwell = sprintf('P%-5.*f', @precision, $phoptions.laser_dwell / 1000.0)
            dwell = stripzeros(dwell, true) # want a plain integer if possible, keeps gplot happy
            out += "G4 #{dwell}\n" # dwell time in seconds, can be less than 1
            out += "M5\n"
            @cc = 'M5'
         end
         cncPrint(out)
      end

      # select between the plungebore options and call the correct method
      def plungebore(xo, yo, zStart, zo, diam, ang = 0, cdiam = 0, cdepth = 0, needretract = true)
         if @laser
            plungelaser(xo, yo, zStart, zo, diam)
         else
            if ang > 0
               plungecsink(xo, yo, zStart, zo, diam, ang, cdiam) if cdiam > 0.0
               UI.messagebox('ERROR: cdiam < 0 in plungecsink') if cdiam < 0.0
            else
               if ang < 0
                  plungeCbore(xo, yo, zStart, zo, diam, ang, cdiam, cdepth) if (cdiam > 0.0) && (cdepth > 0.0)
                  UI.messagebox('ERROR: cdiam < 0 in plungecBore') if (cdiam < 0.0) && (cdepth < 0.0)
               else
                  if @depthfirst
                     plungeboredepth(xo, yo, zStart, zo, diam, needretract)
                  else
                     plungeborediam(xo, yo, zStart, zo, diam, needretract)
                  end
               end
            end
         end
      end

      # circles for plungecsink - use for <= 2*bitdiam
      # mod 10 May 2019 to obey overheadgantry for direction of cuts
      def circle(xo, yo, znow, rnow, complete = true)
         out = '' # 'G00' + format_measure('X',xo) + format_measure('Y',yo) + "\n"
         rad = rnow - @bit_diameter / 2.0
         return '' if rad <= 0.1.mm
         # arc into the cut
         feed = feedScale(rnow * 2, @speed_plung)
         cmd = @cw ? 'G02' : 'G03'
         if complete
            out += cmd + format_measure('X', xo) + format_measure('Y', yo - rad) + format_measure('Z', znow) + format_measure('I', 0) + format_measure('J', -rad / 2.0)
            out += format_feed(feed)
            @cs = feed
            out += "\n"
         else
            out += 'G01' + format_measure('Y', yo - rad) + "\n"
         end
         #      out += 'G03' + format_measure('X', xo-rad) + format_measure('Y',yo) + format_measure('R',rad) + "\n"
         # cut a full circle in quadrants
         if @cw
            out += cmd + format_measure('X', xo - rad) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', rad)
            if @cs != feed
               out += format_feed(feed)
               @cs = feed
            end
            out += "\n"
            out += cmd + format_measure('X', xo) + format_measure('Y', yo + rad) + format_measure('I', rad) + format_measure('J', 0) + "\n"
            out += cmd + format_measure('X', xo + rad) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', -rad) + "\n"
            out += cmd + format_measure('X', xo) + format_measure('Y', yo - rad) + format_measure('I', -rad) + format_measure('J', 0) + "\n"
         else
            out += cmd + format_measure('X', xo + rad) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', rad)
            if @cs != feed
               out += format_feed(feed)
               @cs = feed
            end
            out += "\n"
            out += cmd + format_measure('X', xo) + format_measure('Y', yo + rad) + format_measure('I', -rad) + format_measure('J', 0) + "\n"
            out += cmd + format_measure('X', xo - rad) + format_measure('Y', yo) + format_measure('I', 0) + format_measure('J', -rad) + "\n"
            out += cmd + format_measure('X', xo) + format_measure('Y', yo - rad) + format_measure('I', rad) + format_measure('J', 0) + "\n"
         end
         out
      end

      # zStart : start Z level
      # zo     : end Z level
      # diam   : diameter of hole
      # cdiam  : outside diameter of countersink
      def plungecsink(xo, yo, zStart, zo, diam, ang, cdiam)
         #@debug = true
         cncPrintC("plungeCSINK #{sprintf('X%0.2f', xo.to_mm)},#{sprintf('Y%0.2f', yo.to_mm)},zs #{sprintf('%0.2f', zStart.to_mm)},zo #{sprintf('%0.3f', zo.to_mm)}")
         cncPrintC("diam #{sprintf('%0.2f', diam.to_mm)}, #{sprintf('%0.2fdeg', ang)}, #{sprintf('cdiam %0.2f', cdiam.to_f.to_mm)}")

         # first drill the center hole
         cncPrint("(csink plunge the hole)\n") if @debug
         ucwas = $phoptions.usecomments?
         $phoptions.usecomments = false unless @debug
         plungebore(xo, yo, zStart, zo, diam, 0, 0, 0, false)
         $phoptions.usecomments = ucwas
         cncPrint("(csink end of plunge)\n") if @debug

         outR = cdiam.to_f / 2.0    # radius to cut to
         downS = 0.25.mm            # step down for each layer - if this changes change the rEnd offset
         alpha = ang / 2.0          # side wall angle - in degrees
         xf = Math.tan(PhlatScript.torad(alpha)) * downS # x step to reduce radius by each step
         puts "outR #{outR.to_mm}"     if @debug
         puts "downS #{downS.to_mm}"   if @debug
         puts "alpha #{alpha}"         if @debug
         puts "xf #{xf.to_mm}"         if @debug
         xf = @bit_diameter / 2 if xf > @bit_diameter
         hbd = @bit_diameter / 2
         rNow = outR # starting radius
         rEnd = [diam / 2.0, @bit_diameter / 2.0].max + 0.0125.mm # stop when less than this
         cncPrintC("rEnd #{rEnd.to_l}") if @debug

         zNow = zStart
         cncPrintC("CSINK @cz #{@cz.to_mm}") if @debug
         if notequal(@cz, zStart + 0.5.mm)
            cncPrint("(csink rapid to near surface #{@cz.to_mm})\n") if @debug
            output = 'G00' + format_measure('Z', zStart + 0.5.mm) + "\n" # rapid to near surface - should be a hole there!
         else
            cncPrint("(csink avoided rapid to near surface)\n") if @debug
            output = ''
         end
         # get to surface, no need to start above surface level
         output += 'G01' + format_measure('Z', zStart + 0.02.mm) + format_feed(@speed_plung) + "\n"
         @cz = zStart + 0.02.mm

         # @speed_curr  = PhlatScript.feedRate
         # @speed_plung = PhlatScript.plungeRate
         @cs = @speed_plung

         zEnd = zStart - @material_thickness
         output += "(zEnd #{zEnd})\n" if @debug

         while rNow > rEnd
            zNow -= downS

            if (zNow - zEnd) <= 0.001
               puts 'not going deeper than material' if @debug
               break
            end
            output += "(circle znow #{zNow.to_mm} Rnow #{rNow.to_mm})\n" if @debug

            ynow = 0
            cnt = 0
            if rNow <= @bit_diameter # radius less than bitdiam === diam < 2*bitdiam
               output += "(plain)\n" if @debug
               output += 'G00' + format_measure('X', xo) + format_measure('Y', yo) + "\n"
               output += 'G00' + format_measure('Z', zNow + downS) + "\n" if cnt != 0
               circ = circle(xo, yo, zNow, rNow)
               if circ != ''
                  output += circ
                  output += 'G00' + format_measure('Y', yo - (rNow - hbd) + 0.003) + format_measure('Z', zNow + 0.002) + "\n"
               end
               output += "(plain done)\n" if @debug
            else
               if diam > (@bit_diameter * 2)
                  # arc from center to start point
                  dd = (diam / 2) - (@bit_diameter / 2) # diameter of arc to centerbore edge
                  yy = yo - dd
                  rr = -dd / 2
                  output += "(ARC TO EXISTING HoLE)\n"
                  output += "(dd #{dd.to_mm} yy #{yy.to_mm} rr #{rr.to_mm})\n" if @debug
                  output += 'G00' + format_measure('X', xo) + format_measure('Y', yo) + "\n"
                  if @cw
                     output += 'G02' + format_measure('Y', yy) + format_measure('Z', zNow) + format_measure('I0.0 J', rr)
                  else
                     output += 'G03' + format_measure('Y', yy) + format_measure('Z', zNow) + format_measure('I0.0 J', rr)
                  end
                  @cs = feedScale(diam, @speed_curr)
                  output += format_feed(@cs) 
                  output += "\n"
                  @cs = @speed_curr
               else
                  output += "(STEPPED FOR #{rNow.to_mm} )\n" if @debug
                  output += 'G00' + format_measure('X', xo) + format_measure('Y', yo) + "\n"
                  output += circle(xo, yo, zNow, @bit_diameter) # first cut 2xbit hole
               end
               output += "(SPIRAL rNow #{rNow.to_mm})\n" if @debug
               ystep = PhlatScript.stepover * @bit_diameter / 100
               @cboreinner = diam if diam > (@bit_diameter * 2)
               ystep = GetFuzzyYstep(rNow * 2, ystep, true, true).abs # mustramp false to start from bitdiam hole
               output += @debugc  if @debug && (@debugc != '')
               output += "   (YSTEP #{ystep.to_mm})\n" if @debug
               output += SpiralOut(xo, yo, zStart, zNow, rNow - hbd, ystep) # now spiralout from there
               @cboreinner = 0
               output += 'G00' + format_measure('Y', yo - (rNow - hbd) + 0.003) + format_measure('Z', zNow + 0.002) + "\n"
               output += "(SPIRAL rNow #{rNow.to_mm} done)\n" if @debug
            end
            rNow -= xf
            cnt += 1
         end # while

         output += 'G00' + format_measure('Y', yo)      # back to circle center
         output += format_measure(' Z', @retract_depth) # retract to real safe height
         output += "\n"
         cncPrint(output)
         #      @debug = false
      end

      # beta testers wanted a counterbore option, so here it is
      # * ang will be -90
      # * +xo+ - X center
      # * +yo+ - Y center
      # * +zStart+ - Z start level
      # * +zo+ - Z hole depth
      # * +diam+ - hole diameter
      # * +ang+ - Set to -90 to indicate this is a counterbore
      # * +cdiam+ - counterbore diam
      # * +cdepth+ - counterbore depth, must be < material thickness
      # * calls plungebore() for the 2 holes
      def plungeCbore(xo, yo, zStart, zo, diam, _ang, cdiam, cdepth)
         # @debug = true
         if @debug
            cncPrintC("plungeCBORE #{sprintf('X%0.2f', xo.to_mm)},#{sprintf('Y%0.2f', yo.to_mm)},zs #{sprintf('%0.2f', zStart.to_mm)},zo #{sprintf('%0.2f', zo.to_mm)}")
            cncPrintC("   diam#{sprintf('%0.2f', diam.to_mm)}, cdiam #{sprintf('%0.2f', cdiam.to_f.to_mm)}, cdepth #{sprintf('%0.2f', cdepth.to_f.to_mm)}")
         else
            c = 'plungeCBORE' + format_measure('diam', diam) + format_measure('cdiam', cdiam) + format_measure('cdepth', cdepth) + ' '
            c = c.gsub(/0 /, ' ') while c.include?('0 ')
            c = c.gsub('. ', '.0 ')
            cncPrintC(c)
         end

         # first drill the center hole
         cncPrintC("(cbore plunge the hole)\n") if @debug
         ucwas = $phoptions.usecomments?
         $phoptions.usecomments = false unless @debug
         plungebore(xo, yo, zStart, zo, diam, 0, 0, 0, false)
         $phoptions.usecomments = ucwas
         cncPrintC("(cbore end of plunge)\n") if @debug

         # now do the counterbore
         cncPrintC("(plunge the cbore )\n")        if @debug
         puts "cdepth #{cdepth} cdiam #{cdiam}"    if @debug
         oldramp = PhlatScript.mustramp?
         unless oldramp # ramp not on, set angle to 0
            oldangle = PhlatScript.rampangle
            PhlatScript.rampangle = 0
         end
         PhlatScript.mustramp = true # force ramping on to avoid center drill cycle
         ucwas = $phoptions.usecomments?
         $phoptions.usecomments = false                     unless @debug
         cncPrintC('cbore call plungebore for the cbore')   if @debug
         @cboreinner = diam    if diam >= (@bit_diameter * 2) # set inner diameter if relevant
         plungebore(xo, yo, zStart, zStart - cdepth.to_f, cdiam.to_f)
         @cboreinner = 0
         cncPrintC('cbore call plungebore returned') if @debug
         $phoptions.usecomments = ucwas
         PhlatScript.mustramp = oldramp
         PhlatScript.rampangle = oldangle unless oldramp # if it was off, reset the angle
         cncPrintC("cbore done\n")

         #       output = "G00" + format_measure("Y",yo)      # back to circle center
         #       output += format_measure(" Z",@retract_depth) # retract to real safe height
         #       output += "\n"
         #       cncPrint(output)
         # @debug = false
      end

      # swarfer: instead of a plunged hole, spiral bore to depth, depth first (the old way)
      # handles multipass by itself, also handles ramping
      # @cboreinner: set this to the previously bored inner hole of a cbore, then we can start there for the cbore
      # * +diam+ - final diameter
      def plungeboredepth(xo, yo, zStart, zo, diam, needretract = true)
         # @debug = true
         cz = @retract_depth
         cy = yo
         zos = format_measure('depth=', (zStart - zo))
         ds = format_measure(' diam=', diam)
         cncPrintC("(plungeboredepth #{zos} #{ds})\n")
         if zo > @max_z
            zo = @max_z
         elsif zo < @min_z
            zo = @min_z
         end
         command_out = ''

         cncPrintC("HOLEdepth #{sprintf('%0.2f', diam.to_mm)} dia at #{sprintf('%0.2f', xo.to_mm)},#{sprintf('%0.2f', yo.to_mm)} DEPTH #{sprintf('%0.2f', (zStart - zo).to_mm)}\n") if @debug
         puts " (HOLEdepth #{diam.to_mm} dia at #{xo.to_mm},#{yo.to_mm} DEPTH #{(zStart - zo).to_mm})\n" if @debug
         cncPrintC("needretract=#{needretract}")   if @debug
         cncPrintC("cboreinner #{@cboreinner}")    if @debug
         #      xs = format_measure('X', xo)
         #      ys = format_measure('Y', yo)
         #      command_out += "G00 #{xs} #{ys}\n";
         # swarfer: a little optimization, approach the surface faster
         if $phoptions.use_reduced_safe_height?
            sh = (@retract_depth - zStart) / 4 # use reduced safe height
            sh = sh > 0.5.mm ? 0.5.mm : sh
            sh += zStart.to_f if zStart > 0
            if !@canneddrill || PhlatScript.mustramp?
               cncPrintC("pbd  reduced safe height #{sh.to_mm}\n") if @debug
               command_out += 'G00' + format_measure('Z', sh) # fast feed down to safe height
               @cz = cz = sh
               command_out += "\n"
            end
         else
            sh = @retract_depth
         end

         so = @speed_plung # force using plunge rate for vertical moves
         if PhlatScript.useMultipass?
            if PhlatScript.mustramp? && (diam > @bit_diameter)
               flag = false
               if diam > (@bit_diameter * 2)
                  if @cboreinner < (@bit_diameter * 2) # if cboreinner is less than 2D then need to bore to 2D
                     yoff = @bit_diameter / 2 # if cboreinner is > 2D then skip this
                     flag = true
                     command_out += "(pbd ramp bigd)\n" if @debug
                     if @quarters
                        command_out += SpiralAtQ(xo, yo, zStart, zo, yoff)
                     else
                        command_out += SpiralAt(xo, yo, zStart, zo, yoff)
                     end
                     command_out += 'G0' + format_measure('Y', yo - yoff / 2) + "\n"
                  end
               else
                  if PhlatScript.stepover < 50 # act for a hard material
                     if diam > (@bit_diameter * 1.5)
                        yoff = (diam / 2 - @bit_diameter / 2) * 0.7
                        flag = true
                        command_out += "(pbd hard material)\n" if @debug
                        if @quarters
                           command_out += SpiralAtQ(xo, yo, zStart, zo, yoff)
                        else
                           command_out += SpiralAt(xo, yo, zStart, zo, yoff)
                        end
                        command_out += 'G01' + format_measure('Y', yo) + format_measure('Z', zo+0.2.mm) + " (pbd)\n"
                     end
                  end
               end
               if flag
                  command_out += 'G00' + format_measure('Y', yo - yoff / 2) + format_measure('Z', sh) + "\n"
                  cz = sh
               end
            else # diam = bitdiam OR not ramping
               zonow = PhlatScript.tabletop? ? @material_thickness : 0
               if @canneddrill
                  command_out += diam > @bit_diameter ? 'G99' : 'G98'
                  command_out += ' G83'
                  command_out += format_measure('X', xo)
                  command_out += format_measure('Y', yo)
                  command_out += format_measure('Z', zo)
                  command_out += format_measure('R', sh) # retract height
                  command_out += format_measure('Q', PhlatScript.multipassDepth) # peck depth
                  if notequal(so, @cs)
                     command_out += format_feed(so)
                     @cs = so
                  end
                  command_out += "\n"
                  command_out += "G80\n"
               else # manual peck drill cycle
                  command_out += "(pbd peckdrill)\n" if @debug
                  while (zonow - zo).abs > 0.0001
                     zonow -= PhlatScript.multipassDepth
                     zonow = zo if zonow < zo
                     command_out += 'G01' + format_measure('Z', zonow) # plunge the center hole
                     if notequal(so, @cs)
                        command_out += format_feed(so)
                        @cs = so
                     end
                     command_out += "\n"

                     if (zonow - zo).abs < 0.0001 # if at bottom, then retract
                        command_out += 'G00' + format_measure('z', sh) + "\n" # retract to reduced safe
                     else
                        if @quickpeck
                           raise = PhlatScript.multipassDepth <= 0.5.mm ? PhlatScript.multipassDepth / 2 : 0.5.mm
                           raise = 0.2.mm if raise < 0.2.mm
                           command_out += 'G00' + format_measure('z', zonow + raise) + "\n" # raise just a smidge
                           cz = zonow + raise
                        else
                           command_out += 'G00' + format_measure('z', sh) + "\n" # retract to reduced safe
                           cz = sh
                        end
                     end
                  end # while
               end # else canneddrill
            end
         else
            # TODO: - if ramping, then do not plunge this, rather do a spiralat with yoff = bit/2
            # more optimizing, only bore the center if the hole is big, assuming soft material anyway
            if (diam > @bit_diameter) && PhlatScript.mustramp?
               flag = false
               if diam > (@bit_diameter * 2)
                  if @cboreinner < (@bit_diameter * 2) # only do this if cboreinner is less than 2D
                     yoff = @bit_diameter / 2
                     flag = true
                     command_out += "(!multi && ramp yoff #{yoff.to_mm})\n" if @debug
                     if @quarters
                        command_out += SpiralAtQ(xo, yo, zStart, zo, yoff)
                     else
                        command_out += SpiralAt(xo, yo, zStart, zo, yoff)
                     end
                  end
               else
                  if PhlatScript.stepover < 50 && ( diam < (@bit_diameter * 1.5)) # act for a hard material, do initial spiral
                     yoff = (diam / 2 - @bit_diameter / 2) * 0.7
                     flag = true
                     command_out += "(!multi && ramp 0.7 Yoff #{yoff.to_mm})\n" if @debug
                     if @quarters
                        command_out += SpiralAtQ(xo, yo, zStart, zo, yoff)
                     else
                        command_out += SpiralAt(xo, yo, zStart, zo, yoff)
                     end
                  end
               end
               command_out += 'G00' + format_measure('Y', yo - yoff / 2) + "\n"     if flag
               command_out += 'G00' + format_measure('Y', yo - yoff / 2) + format_measure('Z', sh) + "\n" if flag
               cz = sh
            else
               if @canneddrill
                  if diam > @bit_diameter # then prepare for multi spirals by retracting to reduced height
                     #                  command_out += "G00" + format_measure("Z", sh)    # fast feed down to 1/3 safe height
                     #                  command_out += "\n"
                     command_out += 'G99 G81'  # drill with dwell  - gplot does not like this!
                  else
                     command_out += 'G98 G81'  # drill with dwell  - gplot does not like this!
                  end
                  command_out += format_measure('X', xo)
                  command_out += format_measure('Y', yo)
                  command_out += format_measure('Z', zo)
                  command_out += format_measure('R', sh)
                  #               command_out += format_measure("P",0.2/25.4)               # dwell 1/5 second
                  #               command_out += format_measure("Q",PhlatScript.multipassDepth)
                  if notequal(so, @cs)
                     command_out += format_feed(so)
                     @cs = so
                  end
                  command_out += "\n"
                  command_out += "G80\n"
               else
                  command_out += "(plungeboredepth - center hole)\n" if @debug
                  command_out += 'G01' + format_measure('Z', zo) # plunge the center hole
                  if notequal(so, @cs)
                     command_out += format_feed(so)
                     @cs = so
                  end
                  command_out += "\n"
                  command_out += 'G00' + format_measure('z', sh) # retract to reduced safe
                  cz = sh
                  command_out += "\n"
                  command_out += "(plungeboredepth - center hole done cz #{cz.to_mm})\n" if @debug
               end
               @cs = so
            end
         end

         # if DIA is > 2*BITDIA then we need multiple cuts
         yoff = (diam / 2 - @bit_diameter / 2) # offset to start point for final cut
         ystep = yoff / 4
         if diam > (@bit_diameter * 2)
            command_out += "  (MULTI spirals #{yoff.to_l})\n" if @debug
            # if regular step
            #         ystep = @bit_diameter / 2
            # else use stepover
            ystep = PhlatScript.stepover * @bit_diameter / 100

            #########################
            # if fuzzy stepping, calc new ystep from optimized step count
            # find number of steps to complete hole
            if $phoptions.use_fuzzy_holes?
               ystep = GetFuzzyYstep(diam, ystep, PhlatScript.mustramp?, false)
            end
            #######################

            command_out += "(Ystep #{ystep.to_mm})\n" if @debug
            if @cboreinner > 0
               nowyoffset = @cboreinner / 2 - (@bit_diameter / 2) # already have a hole this size
               command_out += "(nowyoffset1 cboreinner #{nowyoffset.to_l})\n" if @debug
            else
               nowyoffset = PhlatScript.mustramp? ? @bit_diameter / 2 : 0
               command_out += "(nowyoffset2  #{nowyoffset.to_l})\n" if @debug
            end
            #         while (nowyoffset < yoff)
            while (nowyoffset - yoff).abs > 0.0001
               nowyoffset += ystep
               if nowyoffset > yoff
                  nowyoffset = yoff
                  command_out +=  "   (nowyoffset3 #{nowyoffset.to_mm} clamped)\n"    if @debug
               else
                  command_out +=  "   (Nowyoffset4 #{nowyoffset.to_mm})\n"            if @debug
               end

               command_out += @quarters ? SpiralAtQ(xo, yo, zStart, zo, nowyoffset) : SpiralAt(xo, yo, zStart, zo, nowyoffset)
               cy = nowyoffset

               #            if (nowyoffset != yoff) # then retract to reduced safe
               next unless (nowyoffset - yoff).abs > 0.0001 # then retract to reduced safe
               command_out += 'G01' + format_measure('Y', yo - nowyoffset + ystep / 2) + "\n"
               command_out += 'G00' + format_measure('Y', yo - nowyoffset + ystep / 2) + format_measure('Z', sh)
               cy = yo - nowyoffset + ystep / 2
               cz = sh
               command_out += "\n"
            end # while
         else
            if diam > @bit_diameter # only need a spiral bore if desired hole is bigger than the drill bit
               command_out += " (SINGLE spiral)\n" if @debug
               command_out += @quarters ? SpiralAtQ(xo, yo, zStart, zo, yoff) : SpiralAt(xo, yo, zStart, zo, yoff)
               if diam < (@bit_diameter * 1.5)
                  command_out += 'G00' + format_measure('Y', yo) + "\n"
                  cy = yo
               else
                  cy = yoff
               end
               cz = sh
            end
            if diam < @bit_diameter
               cncPrintC("NOTE: requested dia #{diam} is smaller than bit diameter #{@bit_diameter}")
            end
         end # if diam > 2bit

         # return to center at safe height
         #      command_out += format_measure(" G1 Y",yo)
         #      command_out += "\n";
         if notequal(yo, cy) || notequal(cz, sh)
            command_out += "(plungeboredepth - return to center retract)\n" if @debug
            command_out += 'G1' + format_measure('Y', yo - yoff + ystep) + "\n"
            cy = yo - yoff + ystep
            command_out += 'G00'
            command_out += format_measure('Y', yo)   if notequal(yo, cy) # back to circle center
            command_out += format_measure('Z', sh) + "\n"
            cz = sh
         end
         if needretract && notequal(sh, @retract_depth) # retract to real safe height
            command_out += "(retract to real safe height)\n" if @debug
            command_out += 'G00'
            command_out += format_measure(' Z', @retract_depth) + "\n"
            cz = @retract_depth
         end
         command_out += "(plungeboredepth - return to center retract done)\n" if @debug
         cncPrint(command_out)

         #      cncPrintC("plungebore end cz #{cz.to_mm}")
         cncPrintC('plungebore end')

         @cx = xo
         @cy = yo
         @cz = cz # @retract_depth or sh
         @cs = so
         @cc = '' # resetting command here so next one is forced to be correct
         # @debug = false
      end

      # Instead of a plunged hole, spiral bore to depth, doing diameter first with an outward spiral.
      # * handles multipass by itself, also handles ramping.
      # * this is different enough from the old plunge bore that making it conditional within 'plungebore'
      # * would make it too complicated
      # * must also obey @cboreinner
      def plungeborediam(xo, yo, zStart, zo, diam, needretract = true)
         # @debug = true
         zos = format_measure('depth=', (zStart - zo))
         ds = format_measure(' diam=', diam)
         cncPrintC("(plungeboreDiam #{zos} #{ds})\n") if diam > (2 * @bit_diameter)
         if zo > @max_z
            zo = @max_z
         elsif zo < @min_z
            zo = @min_z
         end
         command_out = ''

         cncPrintC("HOLEdiam #{sprintf('%0.2f', diam.to_mm)} dia at #{sprintf('X%0.2f', xo.to_mm)},#{sprintf('Y%0.2f', yo.to_mm)} DEPTH #{sprintf('%0.2f', (zStart - zo).to_mm)}\n") if @debug
         puts " (HOLEdiam #{diam.to_mm} dia at #{xo.to_mm},#{yo.to_mm} DEPTH #{(zStart - zo).to_mm})\n" if @debug
         cncPrintC("   cboreinner #{@cboreinner.to_mm}") if @debug && (@cboreinner > 0)
         #      xs = format_measure('X', xo)
         #      ys = format_measure('Y', yo)
         #      command_out += "G00 #{xs} #{ys}\n";
         # swarfer: a little optimization, approach the surface faster
         cz = @retract_depth # keep track of actual current z
         if $phoptions.use_reduced_safe_height?
            sh = (@retract_depth - zStart) / 4 # use reduced safe height
            sh = sh > 0.5.mm ? 0.5.mm : sh
            sh += zStart.to_f if zStart > 0
            if !@canneddrill || PhlatScript.mustramp?
               puts "  reduced safe height #{sh.to_mm}\n" if @debug
               command_out += 'G00' + format_measure('Z', sh) # fast feed down to safe height
               command_out += "\n"
               @cz = sh
               cz = sh
            end
         else
            sh = @retract_depth
         end

         so = @speed_curr # spiral at normal feed speed

         bd2 = 2 * @bit_diameter
         if (diam < bd2) || ((bd2 - diam).abs < 0.0005) # just do the ordinary plunge, no need to handle it here
            cncPrintC('   diam < 2bit - reverting to depth') if @debug
            return plungeboredepth(xo, yo, zStart, zo, diam, needretract)
         end
         # SO IF WE ARE HERE WE KNOW DIAM > 2*BIT_DIAMETER

         # bore the center out now
         if @cboreinner > 0
            command_out += "(  cboreinner avoid center bore)\n" if @debug
         else
            yoff = @bit_diameter / 2
            command_out += "(plungediam: do center)\n" if @debug
            command_out += @quarters ? SpiralAtQ(xo, yo, zStart, zo, yoff) : SpiralAt(xo, yo, zStart, zo, yoff)
            command_out += 'G00' + format_measure('Y', yo) + format_measure('Z', zo + 0.5.mm) + "\n"
            command_out += "(plungediam: center bore complete)\n" if @debug
         end
         #      command_out += "G00" + format_measure("Z" , sh)
         #     command_out += "\n"

         # if DIA is > 2*BITDIA then we need multiple cuts
         yoff = (diam / 2 - @bit_diameter / 2) # offset to start point for final cut

         command_out += "  (spiral out)\n"            if @debug
         ystep = PhlatScript.stepover * @bit_diameter / 100
         #      puts "Ystep #{ystep.to_mm}\n" if @debug
         # for outward spirals we are ALWAYS using fuzzy step so each spiral is the same size
         ystep = GetFuzzyYstep(diam, ystep, true, true) # force mustramp true to get correct result

         command_out += "(Ystep fuzzy #{sprintf("%0.2f",ystep.to_mm)})\n" if @debug
         #      if (@cboreinner > 0)
         #         nowyoffset = (@cboreinner / 2) + (@bit_diameter/2)
         #      else
         #         nowyoffset = @bit_diameter/2
         #      end
         #      command_out += "  (nowyoffset #{nowyoffset.to_mm})\n"            if @debug

         if PhlatScript.useMultipass?
            # command_out += "G00" + format_measure("Z" , sh)
            # command_out += "\n"
            zstep = -PhlatScript.multipassDepth
            zstep = StepFromMpass(zStart, zo, zstep)
         else
            zstep = -(zStart - zo)
         end

         command_out += "(zstep = #{zstep.to_mm})\n" if @debug
         cnt = 0
         zonow = PhlatScript.tabletop? ? @material_thickness : 0
         while (zonow - zo).abs > 0.0001
            zonow += zstep # zstep is negative
            zonow = zo if zonow < zo
            # puts "   zonow #{zonow.to_mm}"
            #         command_out += "G01"  + format_measure('Y', yo - @bit_diameter/2) + format_measure("Z",zonow)
            command_out += 'G1' + format_measure('Z', zonow) + "\n"
            cz = zonow
            @precision += 1
            # arc from center to start point
            if @cboreinner > 0
               dd = (@cboreinner / 2) - (@bit_diameter / 2) # diameter of arc to centerbore edge
               yy = yo - dd
               rr = -dd / 2
               command_out += "(dd #{dd.to_mm} yy #{yy.to_mm} rr #{rr.to_mm})\n" if @debug
            else
               yy = yo - @bit_diameter / 2
               rr = -@bit_diameter / 4
            end
            acmd =   @cw ? 'G02' : 'G03'
            so = feedScale( (yo - yy)*2 + @bit_diameter, @speed_curr)
            command_out += "(  so #{so.to_mm})\n" if @debug
            command_out += acmd + format_measure('Y', yy) + format_measure('I0.0 J', rr)
            @precision -= 1
            if notequal(so, @cs)
               #command_out += "(so #{so.to_mm}  @cs #{@cs.to_mm})" if @debug
               command_out += format_feed(so)
               @cs = so
               command_out += "(   so #{so.to_mm}  @cs #{@cs.to_mm})" if @debug
            end
            command_out += "\n"

            command_out += SpiralOut(xo, yo, zStart, zonow, yoff, ystep)
            if PhlatScript.useMultipass? && ((zonow - zo).abs > 0.0001)
               command_out += 'G00' + format_measure('Y', yo - yoff + ystep/3) + format_measure('Z', zonow + 0.2.mm) + "\n" # raise
               cz = zonow + 0.2.mm
               command_out += 'G00' + format_measure('Y', yo) + "\n" # back to hole center
            end
            cnt += 1
            if cnt > 1000
               msg = 'error high count break in plungeborediam'
               cncPrint(msg)
               puts msg
               break
            end
         end # while

         # return to center at safe height
         command_out += "(plungeborediam return to safe center)\n" if @debug
         command_out += 'G00' + format_measure('Y', yo - yoff + 0.2.mm) + format_measure('Z', zo + 0.2.mm) + "\n" # raise
         command_out += 'G00' + format_measure('Y', yo) # back to circle center
         command_out += format_measure('Z', sh) + "\n" # back to safe height
         cz = sh
         if needretract && notequal(sh, @retract_depth)
            command_out += 'G00' if @gforce
            command_out += ' ' + format_measure(' Z', @retract_depth) + "\n" # retract to real safe height
            cz = @retract_depth
         end
         command_out += "(plungeborediam- return to center retract done cz #{cz.to_mm})\n" if @debug
         cncPrint(command_out)

         cncPrintC('plungeborediam end')

         @cx = xo
         @cy = yo
         @cz = cz # need to set this correctly to the actual z height we are at
         @cs = so
         @cc = '' # resetting command here so next one is forced to be correct
         # @debug = false
      end

      # use R format arc movement, suffers from accuracy and occasional reversal by CNC controllers
      # * if radius is <= 0.01.inch then output a linear move since really small radii cause issues with controllers and simulators
      # * If laser is enabled then the correct M3/M4 command is output before the move
      def arcmove(xo, yo = @cy, radius = 0, g3 = false, zo = @cz, so = @speed_curr, cmd = @cmd_arc)
         cmd = @cmd_arc_rev if g3
         # puts "g3: #{g3} cmd #{cmd}"
         # G17 G2 x 10 y 16 i 3 j 4 z 9
         # G17 G2 x 10 y 15 r 20 z 5
         command_out = ''
         if radius > 0.01.inch # is radius big enough?
            command_out += cmd if (cmd != @cc) || @gforce
            @precision += 1 # circles like a bit of extra precision so output an extra digit
            command_out += format_measure('X', xo) # if (xo != @cx) x and y must be specified in G2/3 codes
            command_out += format_measure('Y', yo) # if (yo != @cy)
            if @laser
               if notequal(zo, @cz)
                  depth = laserbright(zo)
                  lcmd = @laser_power_mode ? 'M04' : 'M03'
                  # insert the pwm command before current move
                  command_out = lcmd + ' S' + depth.abs.to_i.to_s + "\n" + command_out
               end
            else
               command_out += format_measure('Z', zo) if zo != @cz # optional Z motion
            end
            command_out += format_measure('R', radius)
            @precision -= 1
            command_out += format_feed(so) if notequal(so, @cs)
            command_out += "\n"
         else # output a linear move instead
            command_out += 'G01'
            cmd = 'G01'
            command_out += format_measure('X', xo) # if (xo != @cx) x and y must be specified in G2/3 codes
            command_out += format_measure('Y', yo) # if (yo != @cy)
            if @laser
               if notequal(zo, @cz)
                  depth = laserbright(zo)
                  lcmd = @laser_power_mode ? 'M04' : 'M03'
                  # insert the pwm command before current move
                  command_out = lcmd + ' S' + depth.abs.to_i.to_s + "\n" + command_out
               end
            else
               command_out += format_measure('Z', zo) if zo != @cz
            end
            command_out += format_feed(so) if notequal(so, @cs)
            command_out += "\n"
         end
         cncPrint(command_out)
         @cx = xo
         @cy = yo
         @cz = zo
         @cs = so
         @cc = cmd
      end

      # http://mathforum.org/library/drmath/view/53027.html
      # two points x1y1 x2y2
      # centerpoint cp
      # radius r
      # return a new centerpoint for this radius that is close to the existing centerpoint
      def findCenters(x1, y1, x2, y2, cp, r)
         q = Math.sqrt((x2 - x1)**2 + (y2 - y1)**2) # dist between points
         # mid point between points (x3, y3).
         x3 = (x1 + x2) / 2
         y3 = (y1 + y2) / 2
         # one answer =- .abs to prevent any negative parameters to sqrt
         xa = x3 + Math.sqrt( (r**2 - (q / 2)**2).abs ) * (y1 - y2) / q
         ya = y3 + Math.sqrt( (r**2 - (q / 2)**2).abs ) * (x2 - x1) / q
         # other answer
         xb = x3 - Math.sqrt( (r**2 - (q / 2)**2).abs ) * (y1 - y2) / q
         yb = y3 - Math.sqrt( (r**2 - (q / 2)**2).abs ) * (x2 - x1) / q

         # which one is closer to cp?
         pa = Geom::Point3d.new(xa, ya, 0.0)
         pb = Geom::Point3d.new(xb, yb, 0.0)
         if cp.distance(pa) < cp.distance(pb)
            return pa
         else
            return pb
         end
      end

      # Use IJ format arc movement, more accurate, definitive direction (2016v1.4c - finds centers)
      # * if print is false then return the string rather than cncprint it, for ramplimitarc
      # * If @laser is enabled then the correct M3/M4 will be output before the move
      # for very small arc segments force a linear move instead
      def arcmoveij(xo, yo, centerx, centery, radius, g3 = false, zo = @cz, so = @speed_curr, cmd = @cmd_arc, print = true)
         cmd = g3 ? @cmd_arc_rev : @cmd_arc
         # puts "g3: #{g3} cmd #{cmd}"
         # G17 G2 x 10 y 16 i 3 j 4 z 9
         # G17 G2 x 10 y 15 r 20 z 5
         command_out = ''
         p1 = Geom::Point3d.new(@cx, @cy, 0.0)
         p2 = Geom::Point3d.new(xo, yo, 0.0)         
         if (p1.distance(p2).abs > 0.02.inch) && (radius > 0.01.inch) # is radius big enough?
            cp = Geom::Point3d.new(centerx, centery, 0.0)
            #   arcmove(xo,yo,radius,g3,zo)
            # always calculate real center, and optionally adjust radius
            
            r1 = cp.distance(p1)
            r2 = cp.distance(p2)
            nradius = (r1 + r2) / 2.0 # new radius as average of the two calculated radii
            # puts "r1 #{r1} r2 #{r2} oldradius #{radius.to_mm}  #{nradius.to_mm}"

            # check if real radius is close to supplied radius + or - a bit diam
            # if it is, use realradius +- bitdiam instead of calculated radius

            diff = nradius - radius
            if (diff < 0) && ((diff + @bit_diameter).abs < 0.1.mm)
               # puts "   radius - bd #{diff.to_mm}"
               radius -= @bit_diameter
               diff = nradius - radius
            else
               if (diff > 0) && ((diff - @bit_diameter).abs < 0.1.mm)
                  # puts "   radius + bd  #{diff.to_mm}"
                  radius += @bit_diameter
                  diff = nradius - radius
               end
            end
            if diff.abs > (@bit_diameter / 2) # just in case....
               radius = nradius
               diff = nradius - radius
            end

            # puts "   old center #{centerx} #{centery} #{radius.to_mm} #{nradius.to_mm} #{diff.to_mm}"
            nc = findCenters(@cx, @cy, xo, yo, cp, radius)
            # puts "   new center #{nc.x} #{nc.y}"
            centerx = nc.x
            centery = nc.y

            command_out += cmd if (cmd != @cc) || @gforce
            @precision += 1 # circles like a bit of extra precision so output an extra digit
            command_out += format_measure('X', xo) # if (xo != @cx) x and y must be specified in G2/3 codes
            command_out += format_measure('Y', yo) # if (yo != @cy)

				#command_out += "(so #{so} @cs #{@cs})"

            if @laser
               if notequal(zo, @cz)
                  depth = laserbright(zo)
                  lcmd = @laser_power_mode ? 'M04' : 'M03'
                  # insert the pwm command before current move
                  command_out = lcmd + ' S' + depth.abs.to_i.to_s + "\n" + command_out
               end
            else
               command_out += format_measure('Z', zo) if zo != @cz # optional Z motion
					# scale the feedrate for this arc diameter V1.5
					so = feedScale( (radius * 2).abs, so)
					#command_out += "(new so #{so.to_mm}  @cs #{@cs.to_mm})"
            end

            i = centerx - @cx
            j = centery - @cy
            command_out += format_measure('I', i)
            command_out += format_measure('J', j)
            @precision -= 1
				if notequal(so, @cs)
               command_out += format_feed(so) 
				end	
            command_out += "\n"
            cncPrint(command_out) if print
         else
            arcmove(xo, yo, 0.005.inch, g3, zo) # will always do a line segment because we lied about the radius
         end
         if print
            @cx = xo
            @cy = yo
            @cz = zo
            @cs = so
            @cc = cmd
         else
            return command_out
         end
      end

      # Send the mill home after retracting
      def home
         if !notequal(@cz, @retract_depth) && !notequal(@cy, 0) && !notequal(@cx, 0)
            @no_move_count += 1
         else
            #retract(@retract_depth)
            #zstr = format_measure('Z', $phoptions.end_z);
            #cncPrint("G53 G0 #{zstr}\n")   
            cncPrint(PhlatScript.gcomment('home at end of job') + "\n") if $phoptions.usecomments?
            if !$phoptions.use_home_height?
               retract($phoptions.end_z,'G53 G0')
               setZ(@retract_depth * 2)
               move(0,0, @retract_depth * 2, 1, 'G0')
            else
               move(0,0, @cz, 1, 'G0')
            end
            
            #cncPrint("\n")
            @cs = 0
            @cc = ''
         end
      end
      
      # return the current Z level
      def getZ
         @cz
      end
      
      #set Z height
      def setZ(nz)
         caller_line = caller.first.split(":")[2]
         puts "setZ : #{caller_line} : #{nz.to_mm}mm"         
         @cz = nz
      end         
      
      #display caller information
      def ringonce(funcname, called)
         cname = called.first
         cname = cname.gsub('C:/Program Files (x86)/Google/Google SketchUp 8/Plugins/Phlatboyz/','...')
         puts "#{funcname} #{cname}" if @debug
      end
      
      # set a comment string that can be added to retract or move commands
      def setComment(comment)
         @pcomment = comment
      end
      
      #set cmd to a new value
      def setCmd(cmd)
         @cc = cmd
      end

      #do a safe move, detecting if a retract before or after is needed
      # @cz is 2*@retract_depth after a G53 Z move
      def safemove(x,y)
         ringonce('safemove',caller) if @debug
         if notequal(getZ, 2 * @retract_depth)
            retract(@retract_depth) if getZ < @retract_depth
            move(x, y)
         else
            move(x, y, 2*@retract_depth, 1, 'G0')
            retract(@retract_depth) 
         end         
      end
   end # class PhlatMill
end # module PhlatScript
