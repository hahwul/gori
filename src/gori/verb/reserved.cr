module Gori
  module Verb
    # Terminal-/structurally-reserved chords the hotkey editor must refuse to bind.
    # `reserved?` returns a human reason (the editor toasts it) or nil when bindable.
    #
    # gori's TUI runs the terminal in raw mode (IXON/ISIG cleared — it uses ^C as a
    # quit KEY), so flow-control/signal chords (^S/^Q/^Z/^\) DO reach the app as
    # distinct chords and are bindable (replay's SNI toggle ships on ^S). What stays
    # reserved here is purely terminal-structural: ^C/^D (quit) and the control bytes
    # ^M/^J/^I/^H/^[ that are INDISTINGUISHABLE from enter/tab/backspace/escape — those
    # actually arrive as the named keys (the bare-name branch fires at runtime; the
    # ctrl+letter branch is defence-in-depth for a directly-built Chord) — plus the
    # bare structural keys the dispatch/editors depend on. (gori-specific guard-claimed
    # chords like ^G/^F/^B/^E are layered on at the Hotkeys facade, not here.)
    module Reserved
      def self.reserved?(chord : Chord) : String?
        if chord.ctrl && !chord.alt && !chord.shift
          ctrl_reserved(chord.key)
        elsif !chord.ctrl && !chord.alt
          bare_reserved(chord)
        end
      end

      private def self.ctrl_reserved(key : String) : String?
        case key
        when "c", "d" then "Ctrl-#{key.upcase} quits gori"
        when "h"      then "Ctrl-H is indistinguishable from Backspace"
        when "i"      then "Ctrl-I is indistinguishable from Tab"
        when "j", "m" then "Ctrl-#{key.upcase} is indistinguishable from Enter"
        when "["      then "Ctrl-[ is indistinguishable from Escape"
        end
      end

      private def self.bare_reserved(chord : Chord) : String?
        case chord.key
        when "enter"     then "Enter is reserved (activate)"
        when "escape"    then "Escape is reserved (back / close)"
        when "tab"       then "Tab is reserved (focus ring)"
        when "backspace" then "Backspace is reserved (delete)"
          # ':' opens the command line in dispatch regardless of the shift modifier (the
          # `ev.char == ':'` guard ignores shift), so reserve it unconditionally.
        when ":" then "':' is reserved (command line)"
        end
      end
    end
  end
end
