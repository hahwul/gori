require "./frame"

module Gori::Screenshot
  # The frame as plain text: what a reader would retype, with nothing about how it looked.
  #
  # The format an operator pastes into an issue, a ticket or a chat window, and the one a
  # `grep` can read. Colour, style and the wrap marks are all dropped — `Screenshot::Ansi`
  # is the lossless text form.
  module Text
    extend self

    # Rows up to the last one with content, each right-stripped, newline-terminated.
    #
    # Right-stripped because a terminal row is padded out to the pane width with spaces and
    # nobody pastes those anywhere on purpose; trailing blank rows go for the same reason
    # every other renderer drops them (a pane is captured at its full height). A frame with
    # nothing on it is the empty string, not a lone newline.
    def render(frame : Frame) : String
      last = frame.last_content_row
      return "" if last < 0
      String.build do |io|
        (0..last).each { |y| io << frame.row_text(y).rstrip << '\n' }
      end
    end
  end
end
