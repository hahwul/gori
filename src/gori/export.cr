require "./export/har"

module Gori
  # Write captured flows out in a standard interchange format, so bytes gori captured can
  # leave the tool: hand a teammate a file, load it into Burp/Charles, or drop it into a
  # browser's network panel. The inverse of `Gori::Import` (#495).
  module Export
  end
end
