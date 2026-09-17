# STUB — replaced wholesale by the W1c package at merge
require "./frame"

module Gori::Screenshot
  # The frame as a raster image. See `Svg` for the vector form this mirrors.
  module Png
    # The largest `scale` a caller may ask for. Settings mirrors it as
    # `MAX_SCREENSHOT_PNG_SCALE` rather than requiring this file, so the clamp can run before
    # the screenshot subsystem is loaded.
    MAX_SCALE = 8

    extend self

    def render(frame : Frame, *, scale : Int32 = 2, title : String? = nil,
               chrome : Bool = true, pad : Int32 = 16) : Bytes
      # Named so the stub's signature is exercised rather than merely declared: the real
      # renderer lands with this exact shape, and a caller written against it compiles now.
      _ = {frame, scale, title, chrome, pad}
      Bytes.empty
    end
  end
end
