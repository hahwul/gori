module Gori::Tui
  # The catalog of destinations the "Send selection to…" picker (space → S) offers:
  # string-handling tools that accept a raw selected string as their input. The
  # SendPicker overlay renders these rows; the Runner routes the chosen one's `tab`
  # to that controller's seeding method (apply_send_to). No TUI/state deps, so the
  # list stays a single trivially-extensible source of truth.
  #
  # Adding a target later (e.g. a Sequencer or Encryption tab) is one line here plus
  # a `when :<tab>` branch in Runner#apply_send_to — no other wiring.
  module SendMenu
    # One offered destination: the row `label`, its mnemonic `key` (unique within the
    # list — the picker dispatches on it), the `tab` symbol the Runner routes to, and
    # a short muted `hint` describing what the target does with the string.
    record Destination, label : String, key : Char, tab : Symbol, hint : String

    # The current string-handling destinations, in display order. First (and only)
    # target for now is the Decoder — the selection becomes a new conversion's input.
    def self.destinations : Array(Destination)
      [
        Destination.new("Decoder", 'd', :decoder, "decode / encode input"),
        Destination.new("JWT", 'j', :jwt, "decode / re-sign / attack a token"),
      ]
    end
  end
end
