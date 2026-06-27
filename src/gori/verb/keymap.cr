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

      # The chords that actually bind `verb` under `os` + `overrides` (user > OS > base).
      def self.effective_chords(verb : Definition,
                                os : OsProfile::Os = OsProfile.active,
                                overrides : Hash(String, Array(Chord)) = NO_OVERRIDES) : Array(Chord)
        return overrides[verb.id] if overrides.has_key?(verb.id)
        OsProfile.overrides_for(os)[verb.id]? || verb.chords
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
