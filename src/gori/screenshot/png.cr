# STUB — replaced wholesale by the W1c package at merge
#
# The CLI (`--format png`) and the MCP `screenshot` tool are written against these exact
# signatures so the two packages can land in either order. Until the real rasterizer arrives
# every call answers "nothing": zero bytes and a zero-by-zero canvas. A surface that treats
# that as success would write an empty file, so both callers check the length.
require "./frame"

module Gori::Screenshot
  # A `Frame` rasterized to a PNG, at `scale`× the 1:1 cell grid.
  module Png
    extend self

    # The largest supersample a caller may ask for. A frame is cols×rows cells and every one
    # of them is drawn, so the cost is quadratic in this number — past 8 an ordinary 132×38
    # capture is a canvas no viewer wants and no chat window can carry.
    MAX_SCALE = 8

    # The PNG bytes. `chrome` draws the rounded window bar `Svg` draws; `title` is the text in
    # it (nil = the frame's own).
    def render(frame : Frame, *, scale : Int32 = 2, title : String? = nil,
               chrome : Bool = true, pad : Int32 = 16) : Bytes
      dimensions(frame, scale: scale, title: title, chrome: chrome, pad: pad)
      Bytes.empty
    end

    # `{width, height}` in pixels for the same arguments `render` would be given, without
    # rasterizing — what a caller needs to refuse an image before it spends the memory.
    def dimensions(frame : Frame, *, scale : Int32 = 2, title : String? = nil,
                   chrome : Bool = true, pad : Int32 = 16) : {Int32, Int32}
      _ = {frame, scale, title, chrome, pad}
      {0, 0}
    end
  end
end
