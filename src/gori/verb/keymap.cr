module Gori
  module Verb
    # Derives keybinding lookup FROM the registry, so keys and palette share one
    # source of truth (P1 — no second place to declare bindings). A Chord is
    # resolved against the active scope, then Global as a fallback.
    class Keymap
      NO_OVERRIDES = {} of String => Array(Chord)

      def initialize(@by_scope : Hash(Scope, Hash(Chord, String)))
      end

      # Build the lookup table, layering OS-profile and user overrides over each verb's
      # base chords (verbs/*.cr). Per verb the precedence is: user override (if the id is
      # present) wins → OS-profile override → the verb's declared chords. A user override
      # of [] yields NO chords, so the verb is UNBOUND (its press falls through).
      def self.build(registry : Registry,
                     os : OsProfile::Os = OsProfile.active,
                     overrides : Hash(String, Array(Chord)) = NO_OVERRIDES) : Keymap
        by_scope = Hash(Scope, Hash(Chord, String)).new
        registry.each do |verb|
          effective_chords(verb, os, overrides).each do |chord|
            (by_scope[verb.scope] ||= {} of Chord => String)[chord] = verb.id
          end
        end
        new(by_scope)
      end

      # The chords that actually bind `verb` under `os` + `overrides` (user > OS > base),
      # with the verb's PINNED chords (see `pinned_chords`) always kept.
      def self.effective_chords(verb : Definition,
                                os : OsProfile::Os = OsProfile.active,
                                overrides : Hash(String, Array(Chord)) = NO_OVERRIDES) : Array(Chord)
        if overrides.has_key?(verb.id)
          # The override replaces the REBINDABLE half only. Order matters: the user's chord
          # stays first, because `binding_for` advertises `.first?` — the row, the palette
          # column and every hint strip must show what the operator just bound, not the pin.
          return (overrides[verb.id] + pinned_chords(verb)).uniq
        end
        OsProfile.overrides_for(os)[verb.id]? || verb.chords
      end

      # The declared chords a user rebind may NOT move, because they mean something the
      # bare key cannot.
      #
      # Exactly one shape qualifies: a verb declaring one PLAIN key plus that same key with
      # Ctrl — the `y` + `^Y` Copy pairs. The two are not aliases for convenience. Bare `y`
      # is READ mode's copy; `^Y` is the copy key in INS, where `y` is a literal character
      # that would REPLACE the selection being copied, and it is deliberately the same chord
      # on every tab that has a text editor. Letting a rebind of `y` carry `^Y` off with it
      # would leave those panes with no way at all to copy an INS selection — which is why
      # `Hotkeys.rebindable?` used to refuse the whole pair rather than risk it, hiding eight
      # Copy verbs from the editor with no row and no reason. Pinning the Ctrl half is what
      # lets the bare half be offered.
      #
      # Kept even for an explicit UNBIND (`[]`): "y should do nothing here" is a statement
      # about READ mode, and it must not silently disarm INS copy as well.
      def self.pinned_chords(verb : Definition) : Array(Chord)
        cs = verb.chords
        return NO_PINS unless cs.size == 2
        a, b = cs[0], cs[1]
        return NO_PINS unless a.key == b.key
        plain, ctrl = a.ctrl ? {b, a} : {a, b}
        return NO_PINS unless plain_chord?(plain) && ctrl_only?(ctrl)
        [ctrl]
      end

      NO_PINS = [] of Chord

      private def self.plain_chord?(c : Chord) : Bool
        !c.ctrl && !c.alt && !c.shift
      end

      private def self.ctrl_only?(c : Chord) : Bool
        c.ctrl && !c.alt && !c.shift
      end

      # Turn Settings' string overrides into Chord overrides (one place; unparseable
      # strings are dropped, so a stored empty list stays an explicit unbind).
      def self.parse_overrides(raw : Hash(String, Array(String))) : Hash(String, Array(Chord))
        raw.transform_values { |cs| cs.compact_map { |s| Chord.parse(s) } }
      end

      # Verb id bound to `chord` in `scope` (or globally), if any.
      def lookup(chord : Chord, scope : Scope) : String?
        @by_scope[scope]?.try(&.[chord]?) || @by_scope[Scope::Global]?.try(&.[chord]?)
      end
    end
  end
end
