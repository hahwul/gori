# STUB — replaced wholesale by the W1a core package at merge; keep in sync with the Frame contract
#
# Screenshot: a captured TUI frame, serialized to an image.
#
# `frame.cr` is the model (a grid of styled cells plus the whole-screen facts), `chrome.cr`
# the window dressing derived from the frame's own colours, `font.cr` the embedded bitmap
# font, and `png.cr` a stdlib-only PNG encoder over the two. The capture side and the other
# serializers hang off the same model. `font.cr` is NOT a stub — the line requiring it is what
# the core package has to keep.
require "./screenshot/frame"
require "./screenshot/chrome"
require "./screenshot/font"
