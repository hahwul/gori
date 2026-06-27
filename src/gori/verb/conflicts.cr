module Gori
  module Verb
    # Same-scope keybinding conflict detection for the hotkey editor. A chord clashes
    # ONLY when another verb claims it in the SAME scope — that's the genuine ambiguity
    # (the keymap's `by_scope[scope][chord]` would silently keep just one). Cross-scope
    # reuse is deliberate and must be allowed: the lookup resolves the active scope BEFORE
    # the Global fallback, so a scoped chord intentionally SHADOWS a same-key Global one
    # (e.g. `s` = swap on Comparer / scope-lens elsewhere; `c` = catch-direction on
    # Intercept / capture-toggle elsewhere). Blocking those would forbid bindings gori
    # itself already ships.
    module Conflicts
      record Conflict, chord : Chord, verb_id : String, scope : Scope do
        def message : String
          "#{chord.label} already bound to #{verb_id} in #{scope}"
        end
      end

      def self.overlap?(a : Scope, b : Scope) : Bool
        a == b
      end

      # First verb (other than `verb_id`) whose EFFECTIVE chords include `chord` in an
      # overlapping scope, evaluated against the in-progress `overrides` so two pending
      # rebinds are mutually checked. nil when `chord` is free for `verb_id`.
      def self.detect(registry : Registry, os : OsProfile::Os,
                      overrides : Hash(String, Array(Chord)),
                      verb_id : String, chord : Chord) : Conflict?
        target = registry[verb_id]
        registry.each do |other|
          next if other.id == verb_id
          next unless overlap?(other.scope, target.scope)
          if Keymap.effective_chords(other, os, overrides).includes?(chord)
            return Conflict.new(chord, other.id, other.scope)
          end
        end
        nil
      end
    end
  end
end
