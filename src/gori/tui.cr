require "termisu"

module Gori
  # The terminal UI, built directly on termisu's cell buffer. termisu provides
  # only cells (no widgets/layout), so we supply a tiny immediate-mode drawing
  # layer (Screen) and redraw from state each frame. Rendering goes through a
  # Backend so views can be unit-tested without a real TTY.
  module Tui
    alias Color = Termisu::Color
    alias Attribute = Termisu::Attribute

    # Construct the terminal, turning the "no controlling terminal" failure into a clean
    # message instead of a raw backtrace. Termisu opens /dev/tty directly (independent of
    # STDIN/STDOUT redirection), and raises when there is none — CI, or a detached /
    # background job. `hint` tails the message with how to run interactively. Every
    # interactive entrypoint (the TUI and `gori wizard`) goes through here so the guard
    # lives at the one shared construction point.
    def self.open_terminal(hint : String) : Termisu
      Termisu.new
    rescue IO::Error
      abort "gori: requires an interactive terminal (no /dev/tty) — #{hint}"
    end
  end
end

require "./tui/geometry"
require "./tui/theme"
require "./tui/screen"
require "./tui/frame"
require "./tui/highlight"
require "./tui/layout"
require "./tui/chrome"
