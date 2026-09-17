# STUB — replaced wholesale by the W1c package at merge
#
# `Png` draws glyphs from a bitmap atlas built into the binary, which covers ASCII and the
# box-drawing the TUI chrome is made of. A capture of real traffic carries more than that, so
# an operator can point gori at a full font file and have the rasterizer use it instead.
module Gori::Screenshot
  # The glyph source `Png` rasterizes with.
  module Font
    extend self

    # Arm the rasterizer with `explicit` (a font file path), or with the built-in atlas when
    # it is nil. Called BEFORE `Png.render`, once per render, and never for any other format.
    def use(explicit : String? = nil) : Nil
      _ = explicit
    end
  end
end
