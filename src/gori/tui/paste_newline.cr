require "termisu"
# Without this, the `PasteEnd` half of every mechanism below never arrives on the pinned
# termisu — see the file for the whole story. Required from here so that anything doing paste
# filtering (the Runner, and the specs) gets it; it is the one seam they share.
require "./paste_end_marker_patch"

module Gori
  module Tui
    # Makes one pasted line break insert one newline.
    #
    # Two mechanisms, because terminals differ in whether the first is available.
    #
    # BRACKETED PASTE (the reliable one). `Terminal#enable_bracketed_paste` puts the terminal
    # in DEC mode 2004, after which it wraps a paste in `\e[200~` … `\e[201~` and hands the
    # clipboard bytes over VERBATIM — no CR/LF translation of any kind. The markers arrive as
    # `Key::PasteStart` / `Key::PasteEnd`; both are swallowed here so no view ever sees them,
    # and `pasting?` is true in between. Verbatim delivery is the whole point: a clipboard
    # CRLF really is CR LF, so the pair rule below becomes exact rather than a guess.
    #
    # THE CR-CR PROBLEM this exists for. Without bracketed paste a terminal is free to
    # translate. The reported failure — pasting a request copied from Burp Suite left a blank
    # line after every line — is a terminal that maps the LF of each pasted CRLF to a SECOND
    # CR, so one line break arrives as CR CR: two `Key::Enter`s the pair rule cannot collapse,
    # because CR CR is byte-for-byte what pressing Enter twice looks like. Nothing in the
    # event stream separates those two, which is why the fix had to be the mode rather than a
    # smarter heuristic here (termisu#3).
    #
    # THE PAIR RULE (the fallback, unchanged). Both 0x0D and 0x0A arrive as `Key::Enter`, so
    # on a terminal WITHOUT bracketed paste a pasted CRLF still inserts two newlines. Only the
    # LF of a CR-then-LF pair is dropped: a keyboard Enter is a lone CR and Ctrl+J a lone LF
    # (both still one Enter), and a genuine blank line inside a pasted body is CR LF CR LF —
    # one Enter per pair, so the blank line survives. It stays live even when bracketing is
    # on: it costs nothing there (a bracketed CRLF is the same pair) and it is the only thing
    # standing on a terminal that ignores mode 2004.
    #
    # Lives apart from `Runner` (which needs a tty and so can't be driven from a spec) so the
    # state machine is testable on its own; Runner keeps one and filters every event through
    # it at the single `handle` funnel.
    class PasteNewline
      def initialize
        @after_cr = false
        @in_paste = false
      end

      # True while the events being delivered came from a bracketed paste rather than the
      # keyboard — the seam for a caller that must treat pasted input differently from typing.
      # `Runner#handle` watches its two TRANSITIONS (the markers themselves being swallowed
      # here, they are the only signal a paste began or ended) and uses them for both things
      # that need to know: the bulk-insert fast path, and refusing a paste whose keystrokes
      # would otherwise run as COMMANDS at a focus that takes no text.
      def pasting? : Bool
        @in_paste
      end

      # Force the paste closed without having seen a `PasteEnd` — the only way out when the
      # terminal never sends one (killed mid-transfer, a dropped ssh session, mode 2004
      # turned off under us) or when the parser loses it. `Runner`'s stall watchdog is the
      # caller; `Runner::PASTE_STALL` documents why a quiet input stream is the signal that
      # the marker is not coming. Resets the pair state with it, for exactly the reason the
      # markers themselves do: whatever byte the paste ended on has nothing to do with the
      # next keypress.
      def end_paste : Nil
        @in_paste = false
        @after_cr = false
      end

      # True when the caller must drop `ev` — either a paste boundary marker, or the LF half
      # of a pasted CRLF.
      #
      # Depends on termisu reporting WHICH byte produced the Enter (`Event::Key#char`, set in
      # input/parser.cr). On a build that doesn't, both halves report '\n' — the pair never
      # matches and the rule is inert rather than wrong.
      def swallow?(ev : Termisu::Event::Any) : Bool
        if ev.is_a?(Termisu::Event::Key)
          key = ev.key
          # A marker is not a keystroke, so it never reaches a view. The pair state is reset
          # with it: whatever byte preceded the paste has nothing to do with the paste's first
          # line break, and whatever ended the paste has nothing to do with the next keypress.
          if key.paste_start?
            @in_paste = true
            @after_cr = false
            return true
          elsif key.paste_end?
            @in_paste = false
            @after_cr = false
            return true
          end
        end

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
