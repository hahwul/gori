require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-rules-ov", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Tui::RulesOverlay do
  it "parses the `[req:|resp:] pattern => replacement` syntax" do
    tmp_store do |store|
      ov = RulesOverlay.new(Gori::Rules.load(store))
      ov.parse("resp: Old => New").should eq({Gori::Store::RuleTarget::Response, "Old", "New"})
      ov.parse("req: A => B").should eq({Gori::Store::RuleTarget::Request, "A", "B"})
      ov.parse("bare host").should eq({Gori::Store::RuleTarget::Request, "bare host", ""})
      ov.parse("X-Token: a =>").should eq({Gori::Store::RuleTarget::Request, "X-Token: a", ""})
    end
  end

  it "adds a rule via typed input and renders it" do
    tmp_store do |store|
      rules = Gori::Rules.load(store)
      ov = RulesOverlay.new(rules)
      "resp: nginx => gori".each_char { |c| ov.insert(c) }
      ov.submit.should be_true
      rules.rules.size.should eq(1)
      rules.rules.first.target.should eq(Gori::Store::RuleTarget::Response)

      backend = MemoryBackend.new(80, 14)
      ov.render(Screen.new(backend), Rect.new(0, 0, 80, 14))
      backend.contains?("MATCH & REPLACE").should be_true
      backend.contains?("RES").should be_true
      backend.contains?("nginx → gori").should be_true
    end
  end
end

describe "Match&Replace verb (P1)" do
  it "binds `m` to rules.edit" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("m"), Gori::Verb::Scope::Body).should eq("rules.edit")
  end
end
