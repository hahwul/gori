require "termisu"

module Gori
  module Tui
    # Collapses a pasted CRLF into ONE newline.
    #
    # Both 0x0D and 0x0A arrive as `Key::Enter`, and gori enables no bracketed-paste mode,
    # so pasting CRLF text — what every other HTTP tool puts on the clipboard — inserted a
    # blank line after EVERY line. In the Repeater editor that ends the head right after the
    # request line: the request goes out with no Host header, and the origin answers 400
    # (RFC 9112 §3.2 — an HTTP/1.1 request without Host is malformed).
    #
    # Only the LF of a CR-then-LF pair is dropped. A keyboard Enter is a lone CR and Ctrl+J
    # a lone LF (both still one Enter), and a genuine blank line inside a pasted body is
    # CR LF CR LF — one Enter per pair, so the blank line survives.
    #
    # Lives apart from `Runner` (which needs a tty and so can't be driven from a spec) so
    # the state machine is testable on its own; Runner keeps one and filters every event
    # through it at the single `handle` funnel.
    class PasteNewline
      def initialize
        @after_cr = false
      end

      # True when `ev` is the LF half of a pasted CRLF and the caller must drop it.
      #
      # Depends on termisu reporting WHICH byte produced the Enter (`Event::Key#char`, set
      # in input/parser.cr). On a build that doesn't, both halves report '\n' — the pair
      # never matches and this is inert rather than wrong.
      def swallow?(ev : Termisu::Event::Any) : Bool
        if ev.is_a?(Termisu::Event::Key) && ev.key.enter? && !ev.ctrl? && !ev.alt?
          char = ev.char
          swallow = @after_cr && char == '\n'
          @after_cr = char == '\r'
          swallow
        else
          @after_cr = false
          false
        end
      end
    end
  end
end
