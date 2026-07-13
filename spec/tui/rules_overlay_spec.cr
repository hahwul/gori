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
  it "parses the `[req:|resp:|reqbody:|respbody:] pattern => replacement` syntax" do
    tmp_store do |store|
      ov = RulesOverlay.new(Gori::Rules.load(store))
      head = Gori::Store::RulePart::Head
      body = Gori::Store::RulePart::Body
      req = Gori::Store::RuleTarget::Request
      resp = Gori::Store::RuleTarget::Response
      ov.parse("resp: Old => New").should eq({resp, head, "Old", "New"})
      ov.parse("req: A => B").should eq({req, head, "A", "B"})
      ov.parse("bare host").should eq({req, head, "bare host", ""})
      ov.parse("X-Token: a =>").should eq({req, head, "X-Token: a", ""})
      # body prefixes (tested before the shorter req:/resp: so they aren't mis-split)
      ov.parse("reqbody: pw => hunter2").should eq({req, body, "pw", "hunter2"})
      ov.parse("respbody: SECRET =>").should eq({resp, body, "SECRET", ""})
    end
  end

  it "adds a body rule via typed input and renders its tag" do
    tmp_store do |store|
      rules = Gori::Rules.load(store)
      ov = RulesOverlay.new(rules)
      "respbody: nginx => gori".each_char { |c| ov.insert(c) }
      ov.submit.should be_true
      rules.rules.size.should eq(1)
      rules.rules.first.target.should eq(Gori::Store::RuleTarget::Response)
      rules.rules.first.part.should eq(Gori::Store::RulePart::Body)
      rules.rewrites_response_body?.should be_true

      backend = MemoryBackend.new(80, 14)
      ov.render(Screen.new(backend), Rect.new(0, 0, 80, 14))
      backend.contains?("MATCH & REPLACE").should be_true
      backend.contains?("RES B").should be_true # side + body part tag
      backend.contains?("nginx → gori").should be_true
    end
  end
end

describe "Match&Replace verb (P1)" do
  it "is palette-reachable and keyless by default (L4 — rebind for a Global chord)" do
    reg = Gori::Verbs.registry
    reg["rules.edit"]?.should_not be_nil
    reg["rules.edit"].chords.should be_empty
    keymap = Gori::Verb::Keymap.build(reg)
    keymap.lookup(Gori::Verb::Chord.new("m"), Gori::Verb::Scope::Global).should be_nil
  end
end
