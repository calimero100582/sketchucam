require 'sketchup.rb'
Sketchup.require 'phlatboyz_sketchucam/Phlatboyz/PhlatTool.rb'
Sketchup.require 'phlatboyz_sketchucam/Phlatboyz/PhlatProgress.rb'

module PhlatScript

  class TestTool < PhlatTool

    def initialize
      super
      @tooltype = (PB_MENU_CONTEXT)
    end

    def getContextMenuItems
      return ['Dlg', 'Step', 'Position', 'Close']
    end

    def onContextMenu(menuItem)
      if menuItem == 'Dlg'
        @prog = ProgressDialog.new('Generating GCode...', 3)
      elsif menuItem == 'Step'
        @prog.step
      elsif menuItem == 'Position'
        @prog.position = 2
      elsif menuItem == 'Close'
        @prog.close
      end
    end

  end

end
