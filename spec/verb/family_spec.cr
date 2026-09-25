require "../spec_helper"
require "../support/fake_context"

# The family engine (#1274 WP9) against a synthetic registry: the declaration rules a
# `Verb::Family` holds on its own, how `Registry#register_family` turns an intent into
# membership, and the boot validators' level-1 / level-2 sweeps. The space menu's drawing of
# a family is spec/tui/space_menu_spec.cr.
private alias V = Gori::Verb

private def fam(letters = [{:to_a, 'a'}, {:to_b, 'b'}], key = '>', id = :send, group = :send, sticky = false) : V::Family
  V::Family.new(id, "Send to…", key, group, letters, sticky: sticky)
end

private def verb(id : String, scope = V::Scope::Body, *, intent : Symbol? = nil, mnemonic : Char? = nil,
                 section : Symbol = :common, chords = [] of V::Chord, pinned : Bool = false,
                 hidden : Bool = false) : V::Definition
  V::Definition.new(id, id, "x", scope, chords, hidden: hidden, mnemonic: mnemonic, section: section,
    intent: intent, pinned: pinned) { |_| nil }
end

describe Gori::Verb::Family do
  it "reads its letters, row order and breadcrumb from the one table" do
    f = fam([{:to_b, 'b'}, {:to_a, 'a'}])
    f.letter(:to_a).should eq('a')
    f.letter(:nope).should be_nil
    f.order(:to_b).should eq(0)
    f.order(:to_a).should eq(1)
    f.crumb.should eq("SEND TO")
    f.includes?(:to_a).should be_true
  end

  it "refuses a malformed table" do
    expect_raises(Gori::Error, /gives 'a' to both/) { fam([{:to_a, 'a'}, {:to_b, 'a'}]).validate! }
    expect_raises(Gori::Error, /lists intent :to_a twice/) { fam([{:to_a, 'a'}, {:to_a, 'b'}]).validate! }
    expect_raises(Gori::Error, /has no members/) { fam([] of {Symbol, Char}).validate! }
    expect_raises(Gori::Error, /wipe letter/) { fam(key: 'X').validate! }
    expect_raises(Gori::Error, /band :bogus/) { fam(group: :bogus).validate! }
  end

  it "never gives a member a navigation letter at level 2" do
    V::Family::NAV_LETTERS.each do |nav|
      expect_raises(Gori::Error, /navigation letter/) { fam([{:to_a, nav}]).validate! }
    end
  end
end

describe "Registry#register_family" do
  it "makes every verb naming a family intent a member, registered before or after it" do
    reg = V::Registry.new
    reg.register(verb("demo.early", intent: :to_a))
    reg.register_family(fam)
    reg.register(verb("demo.late", intent: :to_b))
    reg.register(verb("demo.plain", mnemonic: 'p'))

    reg["demo.early"].family.should eq(:send)
    reg["demo.late"].family.should eq(:send)
    reg["demo.plain"].member?.should be_false
    reg.l2_key(reg["demo.early"]).should eq('a')
    reg.l2_key(reg["demo.plain"]).should be_nil
  end

  it "refuses a duplicate id, an intent two families claim, and a lexicon intent" do
    reg = V::Registry.new
    reg.register_family(fam)
    expect_raises(Gori::Error, /duplicate family id/) { reg.register_family(fam(key: '<')) }
    expect_raises(Gori::Error, /in both family :send and :other/) do
      reg.register_family(fam([{:to_a, 'z'}], key: '<', id: :other))
    end
    expect_raises(Gori::Error, /in Verb::Lexicon/) do
      reg.register_family(fam([{:filter, 'z'}], key: '<', id: :third))
    end
  end

  it "takes an unpinned member off level 1 and keeps a pinned one there, on its own letter" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a", intent: :to_a, chords: [V::Chord.new("q")])) # a bare chord…
    reg.register(verb("demo.b", intent: :to_b, mnemonic: 'r', pinned: true))

    reg["demo.a"].menu_key.should be_nil # …does not buy a member a level-1 letter
    reg["demo.a"].menu_listed?.should be_true
    reg["demo.b"].menu_key.should eq('r')
    reg.menu_keys("demo.a").should eq(['>', 'a'])
    reg.menu_keys("demo.b").should eq(['r']) # the shorter path wins
    Gori::Hotkeys.menu_path(reg, "demo.a").should eq("space → > a")
    Gori::Hotkeys.menu_path(reg, "demo.a", compact: true).should eq("␣ > a")
    Gori::Hotkeys.menu_path(reg, "demo.b").should eq("space → r")
    Gori::Hotkeys.expand_menu_paths(reg, "send it with {space:demo.a}").should eq("send it with space → > a")
  end

  it "gives an intent the same level-2 letter in every scope" do
    reg = V::Registry.new
    reg.register_family(fam)
    [V::Scope::Body, V::Scope::Sitemap, V::Scope::Repeater].each do |scope|
      reg.register(verb("#{scope}.a", scope, intent: :to_a))
    end
    reg.select(&.member?).map { |v| reg.l2_key(v) }.uniq!.should eq(['a'])
  end

  it "counts a section whose every verb is a member as a section the menu can show" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a", intent: :to_a, section: :tab))
    reg.has_section?(V::Scope::Body, :tab).should be_true
  end
end

describe "Registry#validate_intents! on families" do
  it "refuses a stray mnemonic on an unpinned member, and allows it on a pinned one" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.pinned", intent: :to_a, mnemonic: 'r', pinned: true))
    reg.validate_intents!
    reg.register(verb("demo.stray", intent: :to_b, mnemonic: 'z'))
    expect_raises(Gori::Error, /only a pinned: member keeps a level-1 letter/) { reg.validate_intents! }
  end

  it "refuses pinned: on a verb no family lists" do
    reg = V::Registry.new
    reg.register(verb("demo.lonely", mnemonic: 'r', pinned: true))
    expect_raises(Gori::Error, /pinned: but no family/) { reg.validate_intents! }
  end

  it "accepts a family intent as known, not an unknown lexicon one" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a", intent: :to_a))
    reg.validate_intents!
    reg.register(verb("demo.typo", intent: :to_zz))
    expect_raises(Gori::Error, /unknown intent :to_zz/) { reg.validate_intents! }
  end

  it "refuses a family key that is one of the strip's letters on a tab with a strip" do
    reg = V::Registry.new
    reg.register_family(fam(key: 'n'))
    reg.register(verb("demo.a", V::Scope::Repeater, intent: :to_a))
    reg.validate_intents! # no strip on the Repeater yet: `n` is an ordinary letter
    reg.register(verb("demo.new", V::Scope::Repeater, intent: :new, section: :subtab))
    expect_raises(Gori::Error, /one of the sub-tab strip's letters/) { reg.validate_intents! }
  end
end

describe "Registry#validate_menu_keys! on families" do
  it "raises when a family key takes a level-1 letter of the same view" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a", intent: :to_a))
    reg.register(verb("demo.gt", mnemonic: '>'))
    expect_raises(Gori::Error, /'>' claimed by both demo.gt and family:send/) { reg.validate_menu_keys! }
  end

  it "reserves the family key only in views that register a member" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a", intent: :to_a, section: :request))
    reg.register(verb("demo.gt", mnemonic: '>', section: :response))
    reg.register(verb("other.gt", V::Scope::Sitemap, mnemonic: '>'))
    reg.validate_menu_keys!
  end

  it "raises on two members of one view answering the same intent" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a1", intent: :to_a))
    reg.register(verb("demo.a2", intent: :to_a, section: :request))
    expect_raises(Gori::Error, /L2 collision: intent :to_a of family :send claimed by both demo.a1 and demo.a2/) do
      reg.validate_menu_keys!
    end
  end

  it "lets two sections that never render together reuse one intent (the request/response hex case)" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.req", intent: :to_a, section: :request))
    reg.register(verb("demo.resp", intent: :to_a, section: :response))
    reg.validate_menu_keys!
  end

  it "sweeps the SUB-TABS bucket's members with every pane view" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.strip", intent: :to_a, section: :subtab))
    reg.register(verb("demo.pane", intent: :to_a, section: :request))
    expect_raises(Gori::Error, /L2 collision/) { reg.validate_menu_keys! }
  end

  it "ignores a hidden member" do
    reg = V::Registry.new
    reg.register_family(fam)
    reg.register(verb("demo.a", intent: :to_a))
    reg.register(verb("demo.hidden", intent: :to_a, chords: [V::Chord.new("z")], hidden: true))
    reg.validate_menu_keys!
  end
end
