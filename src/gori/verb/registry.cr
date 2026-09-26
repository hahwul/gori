require "../fuzzy"

module Gori
  module Verb
    # Holds all verb definitions; the single source the keymap and palette both
    # read from (P1). Space-menu empty lists keep registration order; the Ctrl-P
    # palette (Global, empty query) uses a curated browse order instead.
    class Registry
      include Enumerable(Definition)

      def initialize
        @by_id = {} of String => Definition
        @order = [] of String
        @families = [] of Family
        @openers = {} of String => Symbol
      end

      def register(verb : Definition) : Nil
        raise Gori::Error.new("duplicate verb id: #{verb.id}") if @by_id.has_key?(verb.id)
        @by_id[verb.id] = verb.tagged(verb.intent.try { |i| family_of_intent(i).try(&.id) })
        @order << verb.id
      end

      # Add a space-menu family (#1274 WP9). Every verb whose `intent` the family's letter
      # table names becomes a member — the ones registered already and the ones still to come,
      # so the order of the two calls does not matter. Raises on a malformed family
      # (`Family#validate!`), a duplicate id, an intent another family already claims, or one
      # the lexicon owns: an intent fixes ONE letter, either a level-1 lexicon letter or a
      # family's level-2 one, never both.
      def register_family(family : Family) : Nil
        family.validate!
        raise Gori::Error.new("duplicate family id: #{family.id.inspect}") if family(family.id)
        family.intents.each do |intent|
          if other = family_of_intent(intent)
            raise Gori::Error.new("intent #{intent.inspect} is in both family #{other.id.inspect} and #{family.id.inspect}")
          end
          if Lexicon::ENTRIES.has_key?(intent)
            raise Gori::Error.new(
              "intent #{intent.inspect} is in family #{family.id.inspect} and in Verb::Lexicon " \
              "(a family intent takes its letter from the family table)")
          end
        end
        @families << family
        @order.each do |id|
          v = @by_id[id]
          @by_id[id] = v.tagged(family.id) if (i = v.intent) && family.includes?(i)
        end
      end

      def family(id : Symbol) : Family?
        @families.find { |f| f.id == id }
      end

      # Bind each family's `chord` (`Family#chord`, #1295) in every scope that registers a
      # non-hidden member: one hidden verb per scope, `<family>.open.<scope>`, whose press opens
      # the space menu already inside that family's card (`ExecContext#open_space_family`) —
      # the menu's own path, so no second dispatch. Called once every verb is registered;
      # `validate_chords!` then holds the key like any other, and the R1 guard reads the verb as
      # the family row's own meaning (`#opens_family`).
      def register_family_openers : Nil
        @families.each do |f|
          next unless chord = f.chord
          fid = f.id
          scopes = compact_map { |v| v.scope if v.family == fid && !v.hidden? }.uniq!
          scopes.each do |scope|
            id = "#{fid.to_s.tr("_", "-")}.open.#{scope.to_s.underscore.tr("_", "-")}"
            register(Definition.new(id, f.title, "Open the #{f.title} card", scope, [chord],
              hidden: true) { |ctx| ctx.open_space_family(fid); nil })
            @openers[id] = fid
          end
        end
      end

      # The family `id` opens straight from its tab (a `#register_family_openers` verb), or nil.
      def opens_family(id : String) : Symbol?
        @openers[id]?
      end

      def families : Array(Family)
        @families
      end

      private def family_of_intent(intent : Symbol) : Family?
        @families.find(&.includes?(intent))
      end

      # A member's level-2 letter: its family table's letter for its intent. Nil for a verb
      # that is not a member.
      def l2_key(v : Definition) : Char?
        return nil unless (fid = v.family) && (i = v.intent)
        family(fid).try(&.letter(i))
      end

      # The keys that reach `id` from an open space menu: `[letter]` for a level-1 row (a
      # pinned member included — the shorter path wins), `[family key, letter]` for a member
      # one level down, nil for a verb the menu does not list. Scope-free on purpose: a verb
      # id names one scope, and a family's letters are the same in every scope.
      #
      # A SUB-TABS verb is one level down in a pane view (`SUBTABS_FOLD`, `[T, letter]`) and at
      # level 1 where the strip or the tab bar has focus; `strip_focus` asks for the latter.
      # A pinned one is at level 1 in both.
      def menu_keys(id : String, strip_focus : Bool = false) : Array(Char)?
        return nil unless v = self[id]?
        if k = v.menu_key
          return [SUBTABS_FOLD.key, k] if Registry.folded?(v) && !strip_focus
          return [k]
        end
        return nil unless (fid = v.family) && (f = family(fid)) && (l = l2_key(v))
        [f.key, l]
      end

      def []?(id : String) : Definition?
        @by_id[id]?
      end

      def [](id : String) : Definition
        @by_id[id]? || raise Gori::Error.new("unknown verb id: #{id}")
      end

      # The two sections the space menu renders as ONE "SUB-TABS" bucket. `:subtab` holds the
      # strip's own actions (new/close/duplicate/rename/tag/mark) and `:tab` the strip's
      # search + filter; they are the same idea and only ever differed in which focus level
      # revealed them. Since #1055 the bucket is part of EVERY view of a tab that has a strip:
      # expanded where the strip has focus, one Sub-tabs… row in a pane view (#1274
      # Decision 8), which is why #validate_menu_keys! sweeps both shapes.
      SUBTAB_SECTIONS = {:subtab, :tab}

      # The SUB-TABS bucket as ONE level-1 row in a pane view, "Sub-tabs…" on `T` (#1274
      # Decision 8). Not a registered family: membership is the bucket itself (a verb of a
      # SUBTAB_SECTIONS section), and each member's level-2 letter is its own `menu_key` — the
      # strip's nine, already the same on all nine strips. Where the strip or the tab bar has
      # focus the strip IS the context, so the bucket is drawn expanded at level 1 and there is
      # no Sub-tabs… row (`Registry.folds?`). `T` was Mark all sub-tabs, which is now `T T` from
      # a pane, so the old reflex lands in the right card. `pinned:` keeps a member at level 1
      # in the pane views too (Paste cURL).
      SUBTABS_FOLD = Family.new(:subtabs, "Sub-tabs…", 'T', :none, [] of {Symbol, Char})

      # Whether a view folds the SUB-TABS bucket into the Sub-tabs… row: a tab with a strip,
      # seen from anywhere but the strip itself or the tab bar.
      def self.folds?(section : Symbol, subtabs : Bool) : Bool
        subtabs && !SUBTAB_SECTIONS.includes?(section)
      end

      # A SUB-TABS verb that a pane view draws inside Sub-tabs… rather than at level 1. Not a
      # pinned one, and not a family member, which its family's row already draws.
      def self.folded?(v : Definition) : Bool
        SUBTAB_SECTIONS.includes?(v.section) && !v.pinned? && !v.member?
      end

      # True when scope has at least one non-hidden, MENU-LISTED verb tagged with
      # `section` — lets the tab-bar space menu (@focus == :menu) decide whether a
      # scope has its OWN :tab actions or should fall back to :common instead. Must
      # match what open() actually renders (SpaceMenu#open shows verbs carrying a
      # menu_key, and a family row for its members), else this could report a section that
      # would render empty — or, keyed on `menu_key` alone, drop a section whose every verb
      # sits in a family.
      def has_section?(scope : Scope, section : Symbol) : Bool
        any? { |v| !v.hidden? && v.scope == scope && v.section == section && v.menu_listed? }
      end

      # Whether a verb of section `v_section` is part of the view the space menu draws for
      # `section` — COMMON, the SUB-TABS bucket when the tab has a strip, and the focused pane.
      # The one membership rule `#for_view` and `#registered_in_view` share.
      def self.in_view?(v_section : Symbol, section : Symbol, subtabs : Bool) : Bool
        v_section == :common || v_section == section || (subtabs && SUBTAB_SECTIONS.includes?(v_section))
      end

      # The non-hidden verbs of `scope` that the view REGISTERS, available or not — what a
      # family row is drawn from. A family row is static: whether it shows must not depend on
      # `available?`, or `space > r` typed blind would open level 2 in one state and fall
      # through to the tab's bare `r` in another.
      def registered_in_view(scope : Scope, section : Symbol, subtabs : Bool = false) : Array(Definition)
        self.select { |v| !v.hidden? && v.scope == scope && Registry.in_view?(v.section, section, subtabs) }
      end

      # Fail fast on a space-menu key collision WITHIN a displayable view. A view is
      # COMMON ∪ one context section — that's everything the space menu can show at
      # once (COMMON always renders; at most one section joins it, per #open in
      # SpaceMenu). Two non-hidden verbs deriving the same menu_key (an explicit
      # mnemonic, else the first plain single-char chord) that could appear in the
      # SAME view means the later one is silently unreachable by that key —
      # SpaceMenu#verb_for is a first-match find, so the collision has no other
      # symptom. Two DIFFERENT sections may reuse a key freely (e.g. Repeater's request
      # `i` and response `i`) since they never render together. Cross-scope reuse is
      # likewise fine (the space menu is scoped), mirroring Conflicts' same-scope
      # rule. space_menu_spec asserts the same invariant; calling this at build time
      # makes it a boot-time guarantee, like the duplicate verb-id raise in #register.
      def validate_menu_keys! : Nil
        by_scope = Hash(Scope, Array(Definition)).new { |h, k| h[k] = [] of Definition }
        each { |v| by_scope[v.scope] << v unless v.hidden? }

        by_scope.each do |scope, verbs|
          common = verbs.select { |v| v.section == :common }
          # The SUB-TABS bucket is expanded at level 1 where the strip or the tab bar has
          # focus (COMMON + the bucket), and folded into Sub-tabs… on `T` in every pane view,
          # where only its pinned members keep a level-1 row (#1274 Decision 8). So COMMON may
          # not reuse one of the strip's nine, and a pane may not reuse `T` or a pinned letter.
          strip = verbs.select { |v| SUBTAB_SECTIONS.includes?(v.section) }
          pinned = strip.reject { |v| Registry.folded?(v) } # level 1 in a pane view too
          check_view!(scope, :common, common + strip)
          check_view!(scope, :common, common + pinned, fold: true) unless strip.empty?
          sections = verbs.map(&.section).uniq!.reject { |s| s == :common }
          sections.each do |section|
            view = common + verbs.select { |v| v.section == section }
            if strip.empty? || SUBTAB_SECTIONS.includes?(section)
              check_view!(scope, section, view)
            else
              check_view!(scope, section, view + pinned, fold: true)
            end
          end
        end
      end

      # One displayable view, at both levels of the menu.
      #   • Level 1: every row's key — the level-1 letters (`menu_key`, which a pinned member
      #     keeps) and one key per family that has a member here (`fold`: and Sub-tabs… on `T`).
      #     A family row is drawn when the view REGISTERS a member, not when one is available,
      #     so this is the whole check.
      #   • Level 2: inside each family, no two members of the view on one intent. The letter
      #     comes from the family table, so a duplicate intent is the only way two rows could
      #     share one. Checked per VIEW, not per scope: the Repeater's request and response
      #     panes may each have a hex toggle, since they never render together.
      private def check_view!(scope : Scope, section : Symbol, verbs : Array(Definition), fold : Bool = false) : Nil
        pairs = verbs.compact_map { |v| (k = v.menu_key) ? {k, v.id} : nil }
        pairs << {SUBTABS_FOLD.key, "family:#{SUBTABS_FOLD.id}"} if fold
        verbs.compact_map(&.family).uniq!.each do |fid|
          next unless f = family(fid)
          pairs << {f.key, "family:#{fid}"}
        end
        check_menu_keys!(scope, section, pairs)

        seen = {} of {Symbol, Symbol} => String
        verbs.each do |v|
          next unless (fid = v.family) && (i = v.intent)
          if prior = seen[{fid, i}]?
            raise Gori::Error.new(
              "space-menu L2 collision: intent #{i.inspect} of family #{fid.inspect} claimed by both " \
              "#{prior} and #{v.id} in #{scope}/#{section}")
          end
          seen[{fid, i}] = v.id
        end
      end

      # The scopes no space menu is drawn for: Global is the palette's, and Editor is a keymap
      # scope consulted ahead of the tab while a text editor has focus. A letter derived from
      # their chords never reaches a card.
      NO_SPACE_MENU = {Scope::Global, Scope::Editor}

      # Fail fast on a space-menu letter that breaks the intent lexicon (`Verb::Lexicon`,
      # #1274). Only the rules with no exceptions live here; the reserved-letter sweep, which
      # needs judgement, is `spec/verb/lexicon_spec.cr`.
      #   • An intent must be in the lexicon, and a verb with one must not spell a mnemonic
      #     as well: the lexicon is where its letter comes from, so a second spelling is
      #     either redundant or the drift the table exists to stop.
      #   • ⇧X is the wipe letter app-wide (DESIGN.md §7, 2026-09-12): only a `:wipe` verb in
      #     group :wipe wears it in the menu.
      #   • On a tab with a sub-tab strip, no COMMON verb wears one of the strip's letters
      #     (`Lexicon::STRIP_LETTERS`): COMMON shares the strip-focused card with the expanded
      #     SUB-TABS bucket, and the strip answers `t` raw. It holds on a strip that lacks the
      #     action too, since the nine read the same on all nine strips. A PANE verb is free of
      #     the rule since the bucket folded into Sub-tabs… there (#1274 Decision 8); only the
      #     fold's own `T` stays taken, which #validate_menu_keys! checks per view.
      #   • A family member (#1274 WP9) is the same rule one level down: its letter is the
      #     family table's, so it spells no `mnemonic:` — unless it is `pinned:`, where the
      #     mnemonic is its level-1 letter. Only a member may be pinned: of a family, or of the
      #     SUB-TABS bucket (`SUBTABS_FOLD`), whose pinned rows stay at level 1 in a pane view.
      #   • A family's key is a level-1 letter like any other: on a strip tab it is not one of
      #     the strip's.
      #   • No menu letter is h/j/k/l (`Family::NAV_LETTERS`): inside the menu those four move
      #     the selection, so a row on one would run where the hand meant to move (#1274).
      #   • A palette-only verb (`menu: :palette`, #1282) has no row at either level, so it
      #     spells no `mnemonic:` (a letter no card draws), is never a family member or pinned
      #     (its family would draw it), and is never hidden (the palette would not list it
      #     either, leaving only its chords). It is ignored by every letter rule above.
      def validate_intents! : Nil
        strip_scopes = compact_map { |v| v.scope if SUBTAB_SECTIONS.includes?(v.section) }.to_set
        each do |v|
          check_placement!(v)
          check_intent!(v)
          check_reserved_menu_letter!(v, strip_scopes) unless v.hidden?
        end
        check_family_keys!(strip_scopes)
      end

      private def check_family_keys!(strip_scopes : Set(Scope)) : Nil
        @families.each do |f|
          next unless Lexicon::STRIP_LETTERS.includes?(f.key)
          if v = find { |m| m.family == f.id && !m.hidden? && strip_scopes.includes?(m.scope) }
            raise Gori::Error.new(
              "family #{f.id.inspect} has key '#{f.key}', one of the sub-tab strip's letters, and a " \
              "member (#{v.id}) on #{v.scope}, which has a strip")
          end
        end
      end

      private def check_placement!(v : Definition) : Nil
        return unless v.palette_only?
        problem = if v.member?
                    "is a member of family #{v.family.inspect}, which lists it in the space menu"
                  elsif m = v.mnemonic
                    "spells mnemonic '#{m}', a letter no space menu draws"
                  elsif v.hidden?
                    "is hidden, which the palette does not list either"
                  end
        return unless problem
        raise Gori::Error.new("#{v.id} is placed menu: :palette but #{problem}")
      end

      private def check_intent!(v : Definition) : Nil
        if v.pinned? && !v.member? && !SUBTAB_SECTIONS.includes?(v.section)
          raise Gori::Error.new("#{v.id} is pinned: but no family lists its intent #{v.intent.inspect} " \
                                "and it is not a SUB-TABS verb")
        end
        return unless intent = v.intent
        if v.member?
          if (m = v.mnemonic) && !v.pinned?
            raise Gori::Error.new(
              "#{v.id} is a member of family #{v.family.inspect} (letter '#{l2_key(v)}') and spells " \
              "mnemonic '#{m}' — only a pinned: member keeps a level-1 letter")
          end
          return
        end
        unless Lexicon::ENTRIES.has_key?(intent)
          raise Gori::Error.new("unknown intent #{intent.inspect} on #{v.id} (add it to Verb::Lexicon or a Verb::Family)")
        end
        if m = v.mnemonic
          raise Gori::Error.new(
            "#{v.id} declares intent #{intent.inspect} (menu '#{Lexicon.letter(intent)}') and " \
            "mnemonic '#{m}' — an intent verb takes its letter from Verb::Lexicon")
        end
      end

      private def check_reserved_menu_letter!(v : Definition, strip_scopes : Set(Scope)) : Nil
        return unless key = v.menu_key
        if Family::NAV_LETTERS.includes?(key) && !NO_SPACE_MENU.includes?(v.scope)
          raise Gori::Error.new(
            "#{v.id} in #{v.scope} wears the menu '#{key}', a navigation letter " \
            "(h/j/k/l move the space menu's selection and are never a row's letter)")
        end
        if key == 'X' && !(v.intent == :wipe && v.group == :wipe)
          raise Gori::Error.new("#{v.id} in #{v.scope} wears the menu 'X', the wipe letter (intent :wipe, group :wipe)")
        end
        return unless v.section == :common && strip_scopes.includes?(v.scope)
        if Lexicon::STRIP_LETTERS.includes?(key)
          raise Gori::Error.new(
            "#{v.id} in #{v.scope}/#{v.section} wears the sub-tab strip's menu '#{key}' " \
            "(a COMMON verb on a tab with a strip shares the strip's card, and takes a letter " \
            "outside #{Lexicon::STRIP_LETTERS.join})")
        end
      end

      # Fail fast on a same-scope CHORD collision, the keybinding sibling of
      # #validate_menu_keys!. Keymap.build is a plain hash assignment per scope, so a
      # second verb claiming a chord SILENTLY SHADOWS the first — the shadowed binding
      # has no other symptom (Verb::Conflicts only ever checks a USER rebind from the
      # hotkey editor; nothing ran against the shipped defaults). Three deliberate
      # divergences from the menu-key sweep:
      #   • HIDDEN verbs are included. A hidden verb has no menu row but absolutely has
      #     chords (body.up/body.down own the arrow keys); skipping them would blind
      #     the check to the nav primitives.
      #   • All three OS profiles are swept via Keymap.effective_chords, because
      #     OsProfile.overrides_for SUBSTITUTES chords per verb — a collision can exist
      #     on a profile this binary wasn't built for. Every editor KEYSET is swept for the
      #     same reason and with more at stake: a keyset SUBSTITUTES a bundle of chords at
      #     once (`vim` moves fifteen select-line verbs onto `⇧V` in one go), so a verb that
      #     later claims one of those letters in one of those scopes would shadow silently,
      #     and only for the operators who picked that keyset.
      #   • Conflicts.detect is NOT reused: that path answers "is this one proposed
      #     user chord free?" and its allowances belong to the editor. This is a strict
      #     boot-time sweep over defaults. Cross-scope reuse stays legal here too
      #     (lookup resolves the active scope before the Global fallback, and gori
      #     ships such shadows deliberately — see Conflicts' comment).
      # Also rejects a DEAD capital-letter chord: Keybind.from_event normalises a typed
      # capital to shift+lowercase, so Chord.new("X") can never fire — a warning half a
      # dozen verb-file comments have been standing in for until now.
      def validate_chords! : Nil
        OsProfile::Os.each do |os|
          Keyset::Kind.each do |ks|
            validate_chords_for!(os, ks)
          end
        end
        each { |v| check_chord_of!(v) }
      end

      # `Definition#chord_of` advertises another verb's chord as this one's, so that chord must
      # reach it: the other verb is in the same scope and its chord is live in this verb's
      # section. The verb declares no chord of its own, which would be the one advertised.
      private def check_chord_of!(v : Definition) : Nil
        return unless via = v.chord_of
        problem = if !v.chords.empty?
                    "declares chords of its own"
                  elsif !(other = self[via]?)
                    "names no registered verb"
                  elsif other.scope != v.scope
                    "names #{via} in #{other.scope}, not #{v.scope}"
                  elsif (secs = other.chord_sections) && !secs.includes?(v.section)
                    "names #{via}, whose chord is not live in #{v.section}"
                  end
        return unless problem
        raise Gori::Error.new("#{v.id} has chord_of: #{via.inspect} but #{problem}")
      end

      private def validate_chords_for!(os : OsProfile::Os, keyset : Keyset::Kind) : Nil
        seen = Hash(Scope, Hash(Chord, String)).new { |h, k| h[k] = {} of Chord => String }
        each do |v|
          Keymap.effective_chords(v, os, Keymap::NO_OVERRIDES, keyset).each do |chord|
            if chord.key.size == 1 && chord.key[0].ascii_uppercase?
              raise Gori::Error.new(
                "dead capital chord: '#{chord.label}' on #{v.id} in #{v.scope} can never fire " \
                "(Keybind.from_event normalises a typed capital to shift+lowercase — " \
                "spell it Chord.new(#{chord.key.downcase.inspect}, shift: true))")
            end
            if prior = seen[v.scope][chord]?
              raise Gori::Error.new(
                "chord collision: '#{chord.label}' claimed by both #{prior} and #{v.id} in #{v.scope} " \
                "(#{os} profile, #{Keyset.name_of(keyset)} keyset)")
            end
            seen[v.scope][chord] = v.id
          end
        end
      end

      # Raise on the first key collision among one displayable view's level-1 rows, given as
      # `{key, row id}` (a family row's id is `family:<id>`).
      private def check_menu_keys!(scope : Scope, section : Symbol, rows : Array({Char, String})) : Nil
        seen = {} of Char => String
        rows.each do |(key, id)|
          if prior = seen[key]?
            raise Gori::Error.new(
              "space-menu key collision: '#{key}' claimed by both #{prior} and #{id} in #{scope}/#{section}")
          end
          seen[key] = id
        end
      end

      def each(& : Definition ->)
        @order.each { |id| yield @by_id[id] }
      end

      def size : Int32
        @order.size
      end

      # Find across ALL scopes: non-hidden, context-available verbs matching `query`
      # by fuzzy subsequence, ranked best-first. The general primitive (used in tests
      # and future surfaces); the two TUI surfaces use the scoped #for_scope / #for_view below.
      def search(query : String, ctx : ExecContext) : Array(Definition)
        rank(self.select { |v| !v.hidden? && v.available?(ctx) }, query)
      end

      # Verbs that fire in EXACTLY `scope` (no Global fallback). The two TUI surfaces split
      # along it:
      #   • Ctrl-P palette → for_scope(Global) — gori-wide app control (settings, capture,
      #     scope/rules, tab nav, quit …). Its empty-query BROWSE is this and nothing else.
      #   • space menu → #for_view — only the FOCUSED area's own actions (Body:
      #     repeater/copy/open …, Repeater: send/new, …).
      # App control never clutters the space menu. The palette's TYPED search also finds the
      # focused area's actions (#for_view again, without the menu_key narrowing), listed ahead
      # of the Global matches (#1282): the space menu has no query line, so search is where an
      # occasional action is found. Per-verb available? gates (e.g. history.copy only when
      # current_tab == :history).
      def for_scope(scope : Scope, ctx : ExecContext, query : String = "") : Array(Definition)
        candidates = self.select { |v| !v.hidden? && v.scope == scope && v.available?(ctx) }
        # Empty Global browse: curated palette order (Settings → Go to → rest → exit).
        # Other scopes keep registration order; fuzzy queries always rank by score.
        return browse_palette(candidates) if query.empty? && scope == Scope::Global
        rank(candidates, query)
      end

      # The focused area's actions — "what can I do here" — in registration order: #for_scope
      # narrowed to COMMON, the SUB-TABS bucket when the tab has a strip (`subtabs`), and the
      # focused `section`. The ONE membership rule both surfaces read (#1282): the space menu
      # draws the menu-listed ones (a family member one level down), the palette's typed
      # search ranks all of them, so a chord-only action is still found by name.
      def for_view(scope : Scope, section : Symbol, ctx : ExecContext, subtabs : Bool = false) : Array(Definition)
        for_scope(scope, ctx).select { |v| Registry.in_view?(v.section, section, subtabs) }
      end

      # Shared filter→rank tail: an empty query keeps registration order (browsable);
      # otherwise fuzzy-score "title id" and sort best-first. Public for the palette, which
      # ranks the captured tab list it holds against each keystroke's query.
      def rank(candidates : Array(Definition), query : String) : Array(Definition)
        return candidates if query.empty?

        scored = candidates.compact_map do |v|
          if score = Gori::Fuzzy.score(query.downcase, "#{v.title} #{v.id}".downcase)
            {v, score}
          end
        end
        scored.sort_by! { |(_, score)| -score }.map { |(v, _)| v }
      end

      # Ctrl-P empty-query order (stable within each group via registration index):
      #   1. Settings
      #   2. Go to … tab jumps, then other Navigation
      #   3. Everything else (Action / System / …)
      #   4. Back to projects, then Quit gori (exit paths always last)
      private def browse_palette(candidates : Array(Definition)) : Array(Definition)
        candidates.each_with_index.to_a.sort_by { |(v, i)| {palette_group(v), i} }.map { |(v, _)| v }
      end

      private def palette_group(v : Definition) : Int32
        return 90 if v.id == "app.back"
        return 99 if v.id == "app.quit"
        case v.category
        in Category::Settings   then 0
        in Category::Navigation then v.id.starts_with?("tab.") ? 1 : 2
        in Category::Action     then 10
        in Category::System     then 10
        end
      end
    end
  end
end
