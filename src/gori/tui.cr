require "termisu"

module Gori
  # The terminal UI, built directly on termisu's cell buffer. termisu provides
  # only cells (no widgets/layout), so we supply a tiny immediate-mode drawing
  # layer (Screen) and redraw from state each frame. Rendering goes through a
  # Backend so views can be unit-tested without a real TTY.
  module Tui
    alias Color = Termisu::Color
    alias Attribute = Termisu::Attribute
  end
end

require "./tui/geometry"
require "./tui/theme"
require "./tui/screen"
require "./tui/frame"
require "./tui/highlight"
require "./tui/layout"
require "./tui/chrome"
