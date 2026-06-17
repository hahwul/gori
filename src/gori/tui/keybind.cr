require "../verb"

module Gori::Tui
  # Translates a termisu key event into a Verb::Chord so the keymap (which is
  # terminal-agnostic) can resolve it. This is the one place TUI key encoding
  # meets the verb layer.
  module Keybind
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
        elsif c = key.to_char
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
