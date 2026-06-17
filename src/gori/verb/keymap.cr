module Gori
  module Verb
    # Derives keybinding lookup FROM the registry, so keys and palette share one
    # source of truth (P1 — no second place to declare bindings). A Chord is
    # resolved against the active scope, then Global as a fallback.
    class Keymap
      def initialize(@by_scope : Hash(Scope, Hash(Chord, String)))
      end

      def self.build(registry : Registry) : Keymap
        by_scope = Hash(Scope, Hash(Chord, String)).new
        registry.each do |verb|
          verb.chords.each do |chord|
            (by_scope[verb.scope] ||= {} of Chord => String)[chord] = verb.id
          end
        end
        new(by_scope)
      end

      # Verb id bound to `chord` in `scope` (or globally), if any.
      def lookup(chord : Chord, scope : Scope) : String?
        @by_scope[scope]?.try(&.[chord]?) || @by_scope[Scope::Global]?.try(&.[chord]?)
      end
    end
  end
end
