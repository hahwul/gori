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

    it "raises on a mnemonic that repeats the lexicon letter too, since it is the lexicon's to spell" do
      reg = LexiconSpec.registry(LexiconSpec.verb("demo.a", mnemonic: '/', intent: :filter))
      expect_raises(Gori::Error, /declares intent :filter/) { reg.validate_intents! }
    end
  end
end
