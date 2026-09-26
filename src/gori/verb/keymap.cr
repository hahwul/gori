module Gori
  module Verb
    # Derives keybinding lookup FROM the registry, so keys and palette share one
    # source of truth (P1 — no second place to declare bindings). A Chord is
    # resolved against the active scope, then Global as a fallback.
    class Keymap
      NO_OVERRIDES = {} of String => Array(Chord)

      def initialize(@by_scope : Hash(Scope, Hash(Chord, String)))
      end

      # Build the lookup table, layering user overrides, the editor KEYSET and the OS profile
      # over each verb's base chords (verbs/*.cr). See `effective_chords` for the precedence.
      def self.build(registry : Registry,
                     os : OsProfile::Os = OsProfile.active,
                     overrides : Hash(String, Array(Chord)) = NO_OVERRIDES,
                     keyset : Keyset::Kind = Keyset.active) : Keymap
        by_scope = Hash(Scope, Hash(Chord, String)).new
        os_overrides = OsProfile.overrides_for(os)
        keyset_overrides = Keyset.overrides_for(keyset)
        # A configured chord is a deliberate choice and wins collisions with untouched
        # defaults. Build each broader layer first so a later registry entry cannot silently
        # steal a chord that the operator or keyset assigned to another verb.
        layers = Array.new(4) { [] of Definition }
        registry.each do |verb|
          layers[layer_of(verb.id, overrides, keyset_overrides, os_overrides)] << verb
        end
        claimed = global_claims(layers, os, overrides, keyset)
        layers.each do |layer|
          layer.each do |verb|
            opener = registry.opens_family(verb.id)
            effective_chords(verb, os, overrides, keyset).each do |chord|
              next if opener && claimed.includes?(chord)
              (by_scope[verb.scope] ||= {} of Chord => String)[chord] = verb.id
            end
          end
        end
        new(by_scope)
      end

      # Which configuration layer binds `id`: 3 the user's rebind, 2 a keyset row, 1 an OS
      # row, 0 the verb's declared chords. `#build` writes the layers in that order, so on a
      # shared chord in one scope the higher layer is the one the key fires.
      def self.layer_of(id : String, overrides : Hash(String, Array(Chord)),
                        keyset_overrides : Hash(String, Array(Chord)),
                        os_overrides : Hash(String, Array(Chord))) : Int32
        if overrides.has_key?(id)
          3
        elsif keyset_overrides.has_key?(id)
          2
        elsif os_overrides.has_key?(id)
          1
        else
          0
        end
      end

      # Whether `chord`, one of `verb`'s effective chords, fires another verb instead: a higher
      # layer put it on a verb of the same scope, and `#build` let that one win. What a hint
      # must not advertise — a default ⇧E Save results that the operator's own ⇧E rebind took
      # (`Hotkeys.binding_for`). Only the configured rows can outrank a verb, so it reads those
      # rather than the whole registry.
      def self.displaced?(registry : Registry, verb : Definition, chord : Chord,
                          os : OsProfile::Os, overrides : Hash(String, Array(Chord)),
                          keyset : Keyset::Kind) : Bool
        keyset_overrides = Keyset.overrides_for(keyset)
        os_overrides = OsProfile.overrides_for(os)
        mine = layer_of(verb.id, overrides, keyset_overrides, os_overrides)
        return false if mine == 3
        {overrides, keyset_overrides, os_overrides}.any? do |rows|
          rows.each_key.any? do |id|
            next false if id == verb.id
            next false unless (other = registry[id]?) && other.scope == verb.scope
            next false unless layer_of(id, overrides, keyset_overrides, os_overrides) > mine
            effective_chords(other, os, overrides, keyset).includes?(chord)
          end
        end
      end

      # The chords a configured layer (user, keyset or OS row) puts on a GLOBAL verb. A family
      # opener (`Registry#register_family_openers`) is a default bound in up to eleven tab
      # scopes, which the lookup consults ahead of Global, so it would shadow that deliberate
      # choice on exactly those tabs — `nav.next-tab` on `>` switching tabs everywhere but
      # History and the Repeater. It stands down instead, like any default the operator's
      # chord collides with; `space >` still opens the card.
      private def self.global_claims(layers : Array(Array(Definition)), os : OsProfile::Os,
                                     overrides : Hash(String, Array(Chord)), keyset : Keyset::Kind) : Set(Chord)
        claimed = Set(Chord).new
        layers[1..].each do |layer|
          layer.each do |verb|
            next unless verb.scope.global?
            effective_chords(verb, os, overrides, keyset).each { |chord| claimed << chord }
          end
        end
        claimed
      end

      # The chords that actually bind `verb`, with the verb's PINNED chords (see
      # `pinned_chords`) always kept. Precedence, most specific first:
      #
      #   1. the USER's own rebind    — settings:keys, per verb
      #   2. the editor KEYSET        — `vim` respells the editor family as a bundle
      #   3. the OS PROFILE           — per-platform divergence (ships empty)
      #   4. the verb's declared chords
      #
      # Each layer REPLACES rather than merges, so an override of `[]` yields NO chords and
      # the verb is UNBOUND (its press falls through). The order is what makes a keyset a
      # better DEFAULT rather than a ceiling: pick `vim` and then move one key, and that key
      # stays moved — the keyset row for it is simply never consulted.
      def self.effective_chords(verb : Definition,
                                os : OsProfile::Os = OsProfile.active,
                                overrides : Hash(String, Array(Chord)) = NO_OVERRIDES,
                                keyset : Keyset::Kind = Keyset.active) : Array(Chord)
        if overrides.has_key?(verb.id)
          # The override replaces the REBINDABLE half only. Order matters: the user's chord
          # stays first, because `binding_for` advertises `.first?` — the row, the palette
          # column and every hint strip must show what the operator just bound, not the pin.
          return (overrides[verb.id] + pinned_chords(verb)).uniq
        end
        # Same rule for a keyset row, and for the same reason: a keyset that moved `y` must
        # not carry INS's `^Y` off with it and leave that pane with no way to copy at all.
        if ks = Keyset.overrides_for(keyset)[verb.id]?
          return (ks + pinned_chords(verb)).uniq
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
        lookup_in(chord, scope) || lookup_in(chord, Scope::Global)
      end

      # Verb id bound to `chord` in EXACTLY `scope` — no Global fallback. What a caller
      # walking a SCOPE CHAIN needs: the Runner consults `Scope::Editor` (the focus
      # dimension), then the active tab's scope, then Global, and has to be able to ask each
      # link on its own so an unavailable verb in one link does not hide the next. #lookup is
      # this plus the Global tail, kept for the callers that only ever wanted the pair.
      def lookup_in(chord : Chord, scope : Scope) : String?
        @by_scope[scope]?.try(&.[chord]?)
      end

      # The id a press of `chord` fires in `scope` right now: down the SCOPE CHAIN — Editor
      # (only while a text editor pane holds focus), then `scope`, then Global — taking the
      # first link whose verb is available AND whose chord is live in the focused section
      # (`Definition#chord_live?`). A link that fails either does not block the links behind
      # it. `Runner#resolve_verb_id` is this with the live context; it lives here, pure, so a
      # spec can walk the chain without a terminal.
      def resolve(chord : Chord, scope : Scope, registry : Registry, ctx : ExecContext) : String?
        if ctx.editor_pane? && (id = live_in(chord, Scope::Editor, registry, ctx))
          return id
        end
        live_in(chord, scope, registry, ctx) || live_in(chord, Scope::Global, registry, ctx)
      end

      private def live_in(chord : Chord, scope : Scope, registry : Registry, ctx : ExecContext) : String?
        return nil unless id = lookup_in(chord, scope)
        verb = registry[id]
        verb.available?(ctx) && verb.chord_live?(ctx) ? id : nil
      end
    end
  end
end
