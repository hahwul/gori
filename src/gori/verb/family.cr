module Gori
  module Verb
    # A verb FAMILY: one row in the space menu that opens a second level holding its members
    # (#1274 WP9). "Send flow to…" is one row with a key of its own, and inside it `f` is
    # Fuzzer on every tab, because at that level nothing else competes for the letter.
    #
    # Membership reuses `Definition#intent`: a verb whose intent appears in `letters` is a
    # member (`Registry#register_family` tags it), and the table is the ONLY place a member's
    # second-level letter is spelled, so the same intent reads the same letter in every scope
    # by construction. The order of `letters` is the order of the rows at level 2.
    #
    # A member has no first-level letter of its own (`Definition#menu_key` is nil) unless it is
    # `pinned:`, which draws it at level 1 as well, under its own letter — the loop action a
    # tab should not have to reach through a second key.
    #
    # Registered on the Registry rather than kept in a constant, so a spec builds a small
    # registry with a demo family the way it builds demo verbs.
    # One letter per destination TOOL, shared by every card that hands something to a tool:
    # the "Send flow to…" family's level 2 and the "Send selection to…" picker
    # (`Tui::SendMenu`). "Sequencer is `s`" then holds in both cards by construction. Decoder
    # keeps the `d` the selection picker taught first, so Discover takes its capital.
    TOOL_LETTERS = {
      :repeater  => 'r',
      :fuzzer    => 'f',
      :comparer  => 'c',
      :miner     => 'm',
      :sequencer => 's',
      :authorize => 'a',
      :discover  => 'D',
      :browser   => 'b',
      :decoder   => 'd',
      :jwt       => 'j',
      :cookie    => 'k',
    } of Symbol => Char

    struct Family
      # The bands a family row may sit in: `Tui::SpaceMenu::GROUP_ORDER` plus the untagged
      # `:none`. `verb/` does not name `Tui`, so the list is spelled here and
      # `spec/tui/space_menu_spec.cr` pins the two together.
      BANDS = {:none, :view, :send, :triage, :copy, :scope, :danger, :wipe}

      # Never a menu letter, at either level or as a family's key (#1274): inside the space
      # menu these four always move the selection, as on every list in the app, so a reflex
      # `j`/`k` can never run a row — least of all in a sticky card that stays up after one ran.
      # `Registry#validate_intents!` holds level 1; `#validate!` holds the key and level 2.
      NAV_LETTERS = {'h', 'j', 'k', 'l'}

      getter id : Symbol
      # The level-1 row's title, ending in `…` like the other rows that open a card.
      getter title : String
      # The level-1 key. It obeys the level-1 rules like any menu letter (`Registry`).
      getter key : Char
      # The semantic band the row sits in (`Definition#group`), whatever its members' own are.
      getter group : Symbol
      # intent → level-2 letter, in level-2 row order.
      getter letters : Array({Symbol, Char})
      # After a member runs, re-open this card at the same row instead of closing — for the
      # toggle families, whose rows show their state (`ExecContext#menu_state`).
      getter? sticky : Bool
      # A bare key that opens this card straight from a tab that has the family, without the
      # `space` first (#1295): Send flow to…'s `>`, the same key its row wears, so a dropped
      # `space` lands in the same card. `Registry#register_family_openers` binds it once per
      # scope that registers a member, as a hidden verb that opens the menu and descends.
      getter chord : Chord?

      def initialize(@id : Symbol, @title : String, @key : Char, @group : Symbol,
                     @letters : Array({Symbol, Char}), @sticky : Bool = false, @chord : Chord? = nil)
      end

      def intents : Array(Symbol)
        @letters.map(&.[0])
      end

      def includes?(intent : Symbol) : Bool
        @letters.any? { |(i, _)| i == intent }
      end

      # The level-2 letter for `intent`, or nil when it is not a member intent.
      def letter(intent : Symbol) : Char?
        @letters.find { |(i, _)| i == intent }.try(&.[1])
      end

      # Where `intent`'s row sits at level 2 (table order), or nil.
      def order(intent : Symbol) : Int32?
        @letters.index { |(i, _)| i == intent }
      end

      # The breadcrumb segment for the level-2 card title: "Send flow to…" → "SEND FLOW TO".
      def crumb : String
        @title.rchop('…').rstrip.upcase
      end

      # The rules a family holds on its own, before any verb is weighed against it. The ones
      # that need the verbs (key collisions per view, strip letters) are `Registry`'s.
      def validate! : Nil
        fail!("has no members") if @letters.empty?
        fail!("key must be a printable ASCII character, not #{@key.inspect}") unless @key.ascii? && @key.printable? && @key != ' '
        fail!("key 'X' is the wipe letter") if @key == 'X'
        fail!("key '#{@key}' is a navigation letter (never h/j/k/l in the space menu)") if NAV_LETTERS.includes?(@key)
        fail!("band #{@group.inspect} is not one of #{BANDS.join(", ")}") unless BANDS.includes?(@group)
        validate_letters!
      end

      private def validate_letters! : Nil
        seen_i = Set(Symbol).new
        seen_l = {} of Char => Symbol
        @letters.each do |(intent, letter)|
          fail!("lists intent #{intent.inspect} twice") unless seen_i.add?(intent)
          if prior = seen_l[letter]?
            fail!("gives '#{letter}' to both #{prior.inspect} and #{intent.inspect}")
          end
          seen_l[letter] = intent
          fail!("gives #{intent.inspect} the navigation letter '#{letter}' (never h/j/k/l at level 2)") if NAV_LETTERS.includes?(letter)
          fail!("gives #{intent.inspect} a non-printable letter") unless letter.ascii? && letter.printable? && letter != ' '
        end
      end

      private def fail!(what : String) : NoReturn
        raise Gori::Error.new("family #{@id.inspect} #{what}")
      end
    end
  end
end
