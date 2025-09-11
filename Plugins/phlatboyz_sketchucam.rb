require 'sketchup.rb'
require 'extensions.rb'

module Phlatboyz
  module SketchUCam

    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('Phlatboyz Tools', 'phlatboyz_sketchucam/Phlatboyz/Phlatscript')
      ex.description = 'A set of tools for marking up Phlatland Sketchup drawings and generating CNC g-code.'
      ex.version     = '2.0.0'
      ex.copyright   = 'Phlatboyz © 2017...2021, Calimero100582 © 2025'
      ex.creator     = 'Phlatboyz'

      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end

  end # module SketchUCam
end # module Phlatboyz
