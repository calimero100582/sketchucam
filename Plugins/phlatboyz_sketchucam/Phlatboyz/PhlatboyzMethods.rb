require 'sketchup.rb'
# General method library
module PhlatScript

def PhlatScript.set_safe_array(x, y, w, h, model=Sketchup.active_model)
	model.set_attribute(Dict_name, Dict_safe_origin_x, x)
	model.set_attribute(Dict_name, Dict_safe_origin_y, y)
	model.set_attribute(Dict_name, Dict_safe_width, w)
	model.set_attribute(Dict_name, Dict_safe_height, h)
  draw_safe_area(model)
end

#format a string with Gcode comments, either '(comment)' or '; comment'
def PhlatScript.gcomment(comment)
   if PhlatScript.usecommentbracket?
      return "(" + comment + ")"
   else
      return "; " + comment
   end
end

#split a string into 'short enough' comments if it is too long for GRBL/UGS
#returns an array of strings ready to output, used by phjoiner
def PhlatScript.gcomments(comment)
   output = Array.new
      string = comment.gsub(/\n/,"")
      string = string.gsub(/\(|\)/,"")  # remove existing brackets
      if (string.length > 70)
         chunks = string.scan(/.{1,68}/)
         chunks.each { |bit|
            bb = PhlatScript.gcomment(bit)
            output += [bb]
            }
      else
         string = PhlatScript.gcomment(string)
         output += [string]
      end
   return output
end



#SWARFER : need this is many places, so centralize the resource.
def PhlatScript.isMetric()
  case Sketchup.active_model.options['UnitsOptions']['LengthUnit']
    when 0,1 then
      is_metric = false
    when 2..4 then
      is_metric = true
    else
      is_metric = false
    end
  return is_metric
end

def PhlatScript.get_safe_array(model=Sketchup.active_model)
	x = model.get_attribute(Dict_name, Dict_safe_origin_x, $phoptions.default_safe_origin_x)
	y = model.get_attribute(Dict_name, Dict_safe_origin_y, $phoptions.default_safe_origin_y)
	w = model.get_attribute(Dict_name, Dict_safe_width, $phoptions.default_safe_width)
	h = model.get_attribute(Dict_name, Dict_safe_height, $phoptions.default_safe_height)
	return [x,y,w,h]
end

def PhlatScript._get_area_point3d_array(x, y, w, h)
	p0 = Geom::Point3d.new(x, y, 0)
	p1 = p0.transform Geom::Transformation.translation(Geom::Vector3d.new( w, 0, 0))
	p2 = p1.transform Geom::Transformation.translation(Geom::Vector3d.new( 0, h, 0))
	p3 = p2.transform Geom::Transformation.translation(Geom::Vector3d.new(-w, 0, 0))
	return [p0,p1,p2,p3]
end

def PhlatScript.get_safe_origin_translation(model=Sketchup.active_model)
	x = model.get_attribute(Dict_name, Dict_safe_origin_x, $phoptions.default_safe_origin_x)
	y = model.get_attribute(Dict_name, Dict_safe_origin_y, $phoptions.default_safe_origin_y)
	return Geom::Transformation.translation(Geom::Vector3d.new(-x, -y, 0))
end

def PhlatScript.get_safe_reflection_translation_old(model=Sketchup.active_model)
	y = model.get_attribute(Dict_name, Dict_safe_origin_y, $phoptions.default_safe_origin_y)
	h = model.get_attribute(Dict_name, Dict_safe_height, $phoptions.default_safe_height)
	origin = Geom::Point3d.new(0, (2*y + h), 0)
	xp = Geom::Vector3d.new(1, 0, 0)
	yp = Geom::Vector3d.new(0,-1, 0)
	zp = Geom::Vector3d.new(0, 0,-1)
	return Geom::Transformation.axes(origin, xp, yp, zp)
end

def PhlatScript.get_safe_reflection_translation(model=Sketchup.active_model)
	x = model.get_attribute(Dict_name, Dict_safe_origin_x, $phoptions.default_safe_origin_x)
	w = model.get_attribute(Dict_name, Dict_safe_width, $phoptions.default_safe_width)
	origin = Geom::Point3d.new((2*x + w), 0, 0)
	xp = Geom::Vector3d.new(-1, 0, 0)
	yp = Geom::Vector3d.new( 0, 1, 0)
	zp = Geom::Vector3d.new( 0, 0,-1)
	return Geom::Transformation.axes(origin, xp, yp, zp)
end

def PhlatScript.get_safe_area_point3d_array(model=Sketchup.active_model)
	safe_array = get_safe_array(model)
	x = safe_array[0]
	y = safe_array[1]
	w = safe_array[2]
	h = safe_array[3]
	return _get_area_point3d_array(x, y, w, h)
end

def PhlatScript.mark_construction_object(in_object)
	in_object.set_attribute(Dict_name, Dict_construction_mark, true)
end

def PhlatScript.erase_construction_objects(model=Sketchup.active_model)
	entities = model.active_entities
	entities_to_erase = Array.new
	entities.each do | entity |
		if(entity.get_attribute(Dict_name, Dict_construction_mark))
			entities_to_erase << entity
		end
	end
	entities_to_erase.each { |entity| entities.erase_entities(entity)}
end

def PhlatScript.add_point_label(in_entities, in_point, in_height, in_align)
	# align:0 - bottom, left
	# align:1 - top, right
	label = in_point.x.to_s+", "+in_point.y.to_s

	g = in_entities.add_group()
   g.name = "safearea#{in_align}"  # needs a name to be exluded from group summary list
	g_entities = g.entities
	construction_point = g_entities.add_3d_text(label, TextAlignLeft, "Times", false, false, in_height, 0.1.inch, 0, true, 0)
	bbox = g.bounds

	v1 = (in_align == 0) ? Geom::Vector3d.new(-bbox.width/2, -1.5*bbox.height, 0) : Geom::Vector3d.new(-bbox.width/2, 0.5*bbox.height, 0)
	t = Geom::Transformation.new(in_point.offset(v1))

	g.move!(t)
	#g.explode()
	return g
end

def PhlatScript.test_safe_area(safe_point3d_array, model=Sketchup.active_model)
	safe_area = (safe_point3d_array[0].distance safe_point3d_array[1]) > 0.5.inch
	safe_area &= (safe_point3d_array[1].distance safe_point3d_array[2]) > 0.5.inch
	return safe_area
end

def PhlatScript.draw_safe_area(model=Sketchup.active_model)
	safe_point3d_array = get_safe_area_point3d_array(model)
	erase_construction_objects(model)

	if(test_safe_area(safe_point3d_array, model))
		begin
			entities = model.active_entities

			mark_construction_object(entities.add_cline(safe_point3d_array[0], safe_point3d_array[1],'-'))
			mark_construction_object(entities.add_cline(safe_point3d_array[1], safe_point3d_array[2],'-'))
			mark_construction_object(entities.add_cline(safe_point3d_array[2], safe_point3d_array[3],'-'))
			mark_construction_object(entities.add_cline(safe_point3d_array[3], safe_point3d_array[0],'-'))

			mark_construction_object(entities.add_cpoint(safe_point3d_array[0]))
			mark_construction_object(entities.add_cpoint(safe_point3d_array[1]))
			mark_construction_object(entities.add_cpoint(safe_point3d_array[2]))
			mark_construction_object(entities.add_cpoint(safe_point3d_array[3]))
         if ((PhlatScript.zerooffsetx > 0) || (PhlatScript.zerooffsety > 0))
            pts = Array.new
            x = PhlatScript.zerooffsetx + safe_point3d_array[0].x
            y = PhlatScript.zerooffsety + safe_point3d_array[0].y
            pts << Geom::Point3d.new(x + 0.1 , y + 0.1, 0)
            pts << Geom::Point3d.new(x - 0.1 , y + 0.1, 0)
            pts << Geom::Point3d.new(x + 0.1 , y - 0.1, 0)
            pts << Geom::Point3d.new(x - 0.1 , y - 0.1, 0)
            pts << Geom::Point3d.new(x + 0.1 , y + 0.1, 0)
            mark_construction_object(entities.add_cline(pts[0], pts[1],'-'))
            mark_construction_object(entities.add_cline(pts[1], pts[2],'-'))
            mark_construction_object(entities.add_cline(pts[2], pts[3],'-'))
            mark_construction_object(entities.add_cline(pts[3], pts[4],'-'))
         end 
         
         mark_construction_object(add_point_label(entities, safe_point3d_array[0], Construction_font_height, 0))
			mark_construction_object(add_point_label(entities, safe_point3d_array[2], Construction_font_height, 1))
		rescue
			UI.messagebox "Exception in draw_safe_area "+$!
			nil
		end
	end
end

# convert degrees to radians   (SK8 needs this, V2014 on has it in the math lib)
   def PhlatScript.torad(deg)
       deg * Math::PI / 180
   end     
#convert radians to degrees
   def PhlatScript.todeg(rad)
      rad * 180 / Math::PI 
   end

end # module PhlatScript
