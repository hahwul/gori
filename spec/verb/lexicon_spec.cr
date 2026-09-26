require "../spec_helper"

# `Verb::Lexicon` (#1274): a recurring intent's space-menu letter is looked up, not spelled per
# verb. The boot half is `Registry#validate_intents!`; the reserved-letter sweep below needs
# judgement, so it lives here.
module LexiconSpec
  extend self

  def verb(id : String, scope = Gori::Verb::Scope::Body, chords = [] of Gori::Verb::Chord,
           mnemonic : Char? = nil, intent : Symbol? = nil, section : Symbol = :common,
           group : Symbol = :none) : Gori::Verb::Definition
    Gori::Verb::Definition.new(id, id, id, scope, chords, mnemonic: mnemonic, intent: intent,
      section: section, group: group) { |_| nil }
  end

  # Every verb the space menu can show (Global and Editor are not menu scopes).
  def menu_rows : Array(Gori::Verb::Definition)
    Gori::Verbs.registry.select do |v|
      !v.hidden? && v.menu_key && !v.scope.global? && !v.scope.editor?
    end
  end

  # Id suffixes that name a lexicon intent. A menu verb ending in one declares that intent,
  # so a new "…filter" row cannot quietly pick its own letter.
  SUFFIX_INTENTS = {
    "filter"           => :filter,
    "filter-subtabs"   => :filter,
    "query"            => :filter,
    "select-line"      => :select_line,
    "clear-selection"  => :clear_selection,
    "send-to"          => :send_selection,
    "copy-as"          => :copy_as,
    "copy"             => :copy,
    "delete"           => :delete,
    "mark-toggle"      => :mark,
    "mark-all"         => :mark_all,
    "mark-clear"       => :mark_clear,
    "export"           => :export,
    "find-subtab"      => :find_subtab,
    "close-subtab"     => :close,
    "rename-subtab"    => :rename,
    "duplicate-subtab" => :duplicate,
    "attach"           => :link,
    "link"             => :link,
    "links"            => :link,
    "add-host"         => :scope_add,
  }

  # Rows whose id names an intent but whose letter is decided elsewhere. Each line names why,
  # and the last example fails once a row stops needing its line.
  SUFFIX_ALLOWED = {
    "mine.filter" => "the strip owns `/` in every Miner view since #1055; the table filter is `F`",
  }

  # {verb, other} pairs where a reserved letter is spent on a different intent in a scope that
  # has the reserved one. Each line names why it stands.
  RESERVED_ALLOWED = {} of {String, String} => String

  def registry(*verbs : Gori::Verb::Definition) : Gori::Verb::Registry
    reg = Gori::Verb::Registry.new
    verbs.each { |v| reg.register(v) }
    reg
  end
end

describe Gori::Verb::Lexicon do
  describe "Definition#menu_key" do
    it "takes an intent verb's letter from the lexicon, ahead of its chord" do
      v = LexiconSpec.verb("demo.filter", chords: [Gori::Verb::Chord.new("f")], intent: :filter)
      v.menu_key.should eq('/')
    end

    it "keeps a scope-local verb on its mnemonic, else its first plain chord" do
      LexiconSpec.verb("demo.a", mnemonic: 'z').menu_key.should eq('z')
      LexiconSpec.verb("demo.b", chords: [Gori::Verb::Chord.new("q")]).menu_key.should eq('q')
    end
  end

  it "gives one intent one letter in every scope" do
    by_intent = Hash(Symbol, Set(Char)).new { |h, k| h[k] = Set(Char).new }
    # A family member's intent is the family table's (spec/tui/space_menu_spec.cr); a pinned
    # member's level-1 letter is its own.
    LexiconSpec.menu_rows.each { |v| (i = v.intent) && !v.member? && by_intent[i] << v.menu_key.not_nil! }
    by_intent.reject { |_, letters| letters.size == 1 }.should be_empty
    by_intent.each { |i, letters| letters.first.should eq(Gori::Verb::Lexicon.letter(i)) }
  end

  it "has no entry that no verb answers" do
    # A palette-only verb (#1282) still answers its intent: the placement is where it is
    # listed, the intent is what it means, and it takes the letter back if it returns to the
    # menu. Mark word, the decoder chain and a rule list's reorder are all palette-only today.
    palette = Gori::Verbs.registry.select(&.palette_only?).compact_map(&.intent)
    used = (LexiconSpec.menu_rows.compact_map(&.intent) + palette).to_set
    (Gori::Verb::Lexicon::ENTRIES.keys.to_set - used).should be_empty
  end

  it "spends a reserved letter on nothing else in a scope that has the intent" do
    rows = LexiconSpec.menu_rows
    found = [] of {String, String}
    rows.group_by(&.scope).each do |_, verbs|
      verbs.each do |owner|
        next unless (i = owner.intent) && Gori::Verb::Lexicon.reserved?(i)
        verbs.each do |v|
          next if v.intent == i || v.menu_key != owner.menu_key
          found << {v.id, owner.id}
        end
      end
    end
    found.uniq!
    found.reject { |pair| LexiconSpec::RESERVED_ALLOWED.has_key?(pair) }.should eq([] of {String, String})
    LexiconSpec::RESERVED_ALLOWED.keys.reject { |pair| found.includes?(pair) }.should eq([] of {String, String})
  end

  it "tags every menu verb whose id names an intent" do
    untagged = LexiconSpec.menu_rows.compact_map do |v|
      want = LexiconSpec::SUFFIX_INTENTS[v.id.rpartition('.').last]?
      next unless want && v.intent != want
      v.id unless LexiconSpec::SUFFIX_ALLOWED.has_key?(v.id)
    end
    untagged.should eq([] of String)
    stale = LexiconSpec::SUFFIX_ALLOWED.keys.reject do |id|
      v = Gori::Verbs.registry[id]
      v.intent != LexiconSpec::SUFFIX_INTENTS[id.rpartition('.').last]
    end
    stale.should eq([] of String)
  end

  describe "Registry#validate_intents!" do
    it "passes on the shipped registry" do
      Gori::Verbs.registry.validate_intents!
    end

    it "raises on an intent the lexicon does not know" do
      reg = LexiconSpec.registry(LexiconSpec.verb("demo.a", intent: :no_such_intent))
      expect_raises(Gori::Error, /unknown intent :no_such_intent/) { reg.validate_intents! }
    end

    it "raises on an intent verb that spells a mnemonic as well" do
      reg = LexiconSpec.registry(LexiconSpec.verb("demo.a", mnemonic: 'f', intent: :filter))
      expect_raises(Gori::Error, /declares intent :filter .* mnemonic 'f'/) { reg.validate_intents! }
    end

    # COMMON shares the strip-focused card with the expanded SUB-TABS bucket; a pane view
    # folds the bucket into Sub-tabs… (#1274 Decision 8), so a pane letter is free of the rule.
    it "raises on a COMMON verb wearing a strip letter on a tab that has a strip, not a pane verb" do
      reg = LexiconSpec.registry(
        LexiconSpec.verb("demo.new", Gori::Verb::Scope::Jwt, intent: :new, section: :subtab),
        LexiconSpec.verb("demo.all", Gori::Verb::Scope::Jwt, mnemonic: 't'))
      expect_raises(Gori::Error, /demo.all .* strip's menu 't'/) { reg.validate_intents! }
      LexiconSpec.registry(
        LexiconSpec.verb("demo.new", Gori::Verb::Scope::Jwt, intent: :new, section: :subtab),
        LexiconSpec.verb("demo.pane", Gori::Verb::Scope::Jwt, mnemonic: 't', section: :output)).validate_intents!
    end

    # h/j/k/l move the menu's selection (#1274): a row on one would run where the hand meant
    # to move, so no row wears one. A chord-derived letter counts as much as a mnemonic.
    it "raises on a menu letter that is h, j, k or l" do
      Gori::Verb::Family::NAV_LETTERS.each do |nav|
        reg = LexiconSpec.registry(LexiconSpec.verb("demo.nav", Gori::Verb::Scope::Notes, mnemonic: nav))
        expect_raises(Gori::Error, /demo.nav .* navigation letter/) { reg.validate_intents! }
      end
      derived = LexiconSpec.verb("demo.chord", Gori::Verb::Scope::Evidence, [Gori::Verb::Chord.new("l")])
      expect_raises(Gori::Error, /demo.chord .* navigation letter/) { LexiconSpec.registry(derived).validate_intents! }
      # Global and Editor draw no space menu, so a letter their chords derive is never a row.
      LexiconSpec.registry(LexiconSpec.verb("demo.ed", Gori::Verb::Scope::Editor, [Gori::Verb::Chord.new("l")])).validate_intents!
      LexiconSpec.registry(LexiconSpec.verb("demo.gl", Gori::Verb::Scope::Global, [Gori::Verb::Chord.new("k")])).validate_intents!
      # A hidden verb has no row.
      LexiconSpec.registry(Gori::Verb::Definition.new("demo.hid", "x", "x", Gori::Verb::Scope::Body,
        [Gori::Verb::Chord.new("j")], hidden: true) { |_| nil }).validate_intents!
    end

    # `menu: :palette` (#1282): no row at either level, so nothing that would draw one.
    it "raises on a palette-only verb that spells a letter, joins a family or hides" do
      palette = ->(id : String, mnemonic : Char?, intent : Symbol?, hidden : Bool) {
        Gori::Verb::Definition.new(id, id, id, Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("q", ctrl: true)],
          hidden: hidden, mnemonic: mnemonic, intent: intent, menu: :palette) { |_| nil }
      }
      reg = LexiconSpec.registry(palette.call("demo.m", 'q', nil, false))
      expect_raises(Gori::Error, /demo.m is placed menu: :palette but spells mnemonic 'q'/) { reg.validate_intents! }

      reg = LexiconSpec.registry(palette.call("demo.f", nil, :to_a, false))
      reg.register_family(Gori::Verb::Family.new(:demo, "Demo…", '>', :send, [{:to_a, 'a'}]))
      expect_raises(Gori::Error, /demo.f is placed menu: :palette but is a member of family :demo/) { reg.validate_intents! }

      reg = LexiconSpec.registry(palette.call("demo.h", nil, nil, true))
      expect_raises(Gori::Error, /demo.h is placed menu: :palette but is hidden/) { reg.validate_intents! }

      # An intent is fine: it names what the verb means, and the verb draws no letter from it.
      ok = palette.call("demo.ok", nil, :filter, false)
      ok.menu_key.should be_nil
      LexiconSpec.registry(ok).validate_intents!
    end

    it "raises on a menu 'X' that is not a wipe" do
      reg = LexiconSpec.registry(LexiconSpec.verb("demo.flip", Gori::Verb::Scope::Rewriter, mnemonic: 'X'))
      expect_raises(Gori::Error, /demo.flip .* the wipe letter/) { reg.validate_intents! }
      LexiconSpec.registry(LexiconSpec.verb("demo.clear", intent: :wipe, group: :wipe)).validate_intents!
    end

    it "leaves the strip's letters free on a tab without a strip" do
      LexiconSpec.registry(LexiconSpec.verb("demo.pane", Gori::Verb::Scope::Body, mnemonic: 't'))
        .validate_intents!
    end

    it "raises on a mnemonic that repeats the lexicon letter too, since it is the lexicon's to spell" do
      reg = LexiconSpec.registry(LexiconSpec.verb("demo.a", mnemonic: '/', intent: :filter))
      expect_raises(Gori::Error, /declares intent :filter/) { reg.validate_intents! }
    end
  end
end
