# STUB — replaced wholesale by the W1a core package at merge; keep in sync with the Frame contract
require "./screenshot/frame"
require "./screenshot/mask"

module Gori
  # A captured TUI frame as data: a grid of styled cells, plus what the renderer knew about it
  # that the grid alone cannot carry (the palette it was drawn in, where the cursor was, which
  # spans are the tail of a wrapped line). The serializers that turn one into an image or a
  # terminal recording are W1a's; this package only produces them.
  module Screenshot
  end
end
