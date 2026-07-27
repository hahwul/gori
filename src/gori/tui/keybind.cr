require "../verb"
require "../hotkeys"

module Gori::Tui
  # Translates a termisu key event into a Verb::Chord so the keymap (which is
  # terminal-agnostic) can resolve it. This is the one place TUI key encoding
  # meets the verb layer.
  module Keybind
    # Fold an ⌥-aliased event for the CLAIMED family back onto its Ctrl form, so the ~51
    # hardcoded `ev.ctrl? && key.lower_p?`-style guards spread across the Runner, the
    # overlays and the controllers keep working untouched. Identity unless
    # Settings.command_modifier is "alt", and identity for anything outside
    # Hotkeys::CLAIMED_KEYS (⌥R stays ⌥R and reaches the keymap normally).
    #
    # Applied per event loop — Runner#handle_key, ProjectPicker, Tutorial — AFTER each
    # loop's ^C/^D quit arm and (in the Runner) after the hotkey-capture branch, so quit
    # stays Ctrl-only and the Hotkeys editor still records ⌥-chords verbatim.
    #
    # Two normalizations matter:
    #   • ⌥⇧P arrives as Key::UpperP (the parser reads "\eP" → from_char('P')), while
    #     Ctrl+Shift+P is byte-identical to ^P. Downcasing the key and clearing Shift makes
    #     both paths land on the same event a `key.lower_p?` guard expects.
    #   • `char: nil` matches what the Ctrl+letter parser branch produces; Event::Key#char
    #     falls back to key.to_char, so the digit guards (`ev.char || key.to_char`) are
    #     unaffected either way.
    #
    # A ⌃⌥-carrying event is left alone: it already satisfies `ev.ctrl?`, so rewriting it
    # would change nothing except the shift/alt flags.
    def self.dealias(ev : Termisu::Event::Key) : Termisu::Event::Key
      return ev unless Hotkeys.alias_active?
      return ev unless ev.alt? && !ev.ctrl?
      c = ev.char || ev.key.to_char
      return ev unless c && Hotkeys::CLAIMED_KEYS.includes?(c.downcase.to_s)
      mods = (ev.modifiers & ~Termisu::Input::Modifier::Alt & ~Termisu::Input::Modifier::Shift) |
             Termisu::Input::Modifier::Ctrl
      Termisu::Event::Key.new(Termisu::Input::Key.from_char(c.downcase), mods, nil)
    end

    # #dealias lifted to the `case ev = poll_event` shape used by the standalone loops
    # (ProjectPicker, Tutorial) — Resize/Mouse/nil pass through untouched.
    def self.dealias_event(ev : Termisu::Event::Any?) : Termisu::Event::Any?
      ev.is_a?(Termisu::Event::Key) ? dealias(ev) : ev
    end

    def self.from_event(ev : Termisu::Event::Key) : Verb::Chord?
      key = ev.key
      shift = ev.shift?
      name =
        if key.enter?
          "enter"
        elsif key.escape?
          "escape"
        elsif key.tab?
          "tab"
        elsif key.up?
          "up"
        elsif key.down?
          "down"
        elsif key.left?
          "left"
        elsif key.right?
          "right"
        elsif key.backspace?
          "backspace"
        elsif key.space?
          "space"
        elsif c = (ev.char || key.to_char)
          # Only ASCII for chord names (Unicode text input is handled by editors directly).
          unless c.ascii?
            return nil
          end
          # Terminals deliver a typed uppercase letter as the char itself with no
          # shift modifier; normalise to shift + lowercase so "shift-f" binds.
          shift ||= c.ascii_uppercase?
          c.downcase.to_s
        else
          return nil
        end

      Verb::Chord.new(name, ctrl: ev.ctrl?, alt: ev.alt?, shift: shift)
    end
  end
end
