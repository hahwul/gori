require "../spec_helper"
require "../support/fake_context"

# The shipped families (#1274 WP9). The engine is spec/verb/family_spec.cr and
# spec/tui/space_menu_spec.cr; this pins what "Send flow to…" promises an operator.
private def members(intent : Symbol) : Array(Gori::Verb::Definition)
  Gori::Verbs.registry.select { |v| v.intent == intent && v.member? && !v.hidden? }
end

# A context in which `v` is available: the flow-bearing gates the send verbs read.
private def ctx_for(v : Gori::Verb::Definition) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.selected = 5_i64
  ctx.fuzzer_has_result = true
  ctx.miner_has_issue = true
  ctx.selected_evidence = 1_i64
  ctx.current_tab = case v.scope
                    when .fuzzer? then :fuzzer
                    when .miner?  then :miner
                    else               :history
                    end
  ctx
end

describe "Send flow to… (#1274 WP9)" do
  family = Gori::Verbs::SEND_FLOW

  it "is registered, on `>`, in the SEND band" do
    Gori::Verbs.registry.family(:send_flow).should eq(family)
    family.key.should eq('>')
    family.group.should eq(:send)
  end

  it "gives each member intent the same level-2 letter in every scope that has it" do
    family.intents.each do |intent|
      found = members(intent)
      found.should_not be_empty, intent.to_s
      found.map { |v| Gori::Verbs.registry.l2_key(v) }.uniq!.should eq([family.letter(intent)]), intent.to_s
    end
  end

  it "spells the tool letters the Send selection to… picker spells" do
    Gori::Tui::SendMenu.destinations.each do |d|
      d.key.should eq(Gori::Verb::TOOL_LETTERS[d.tab])
    end
    family.letter(:to_sequencer).should eq(Gori::Tui::SendMenu.destinations.find!(&.tab.==(:sequencer)).key)
  end

  it "keeps Send to Repeater on its level-1 letter wherever it was one" do
    members(:to_repeater).each do |v|
      v.pinned?.should be_true, v.id
      v.menu_key.should eq(v.scope.fuzzer? || v.scope.miner? ? 'R' : 'r'), v.id
    end
  end

  it "reaches Send to Repeater with `> r` typed blind on every tab that has it" do
    reg = Gori::Verbs.registry
    members(:to_repeater).each do |v|
      ctx = ctx_for(v)
      v.available?(ctx).should be_true, v.id
      menu = Gori::Tui::SpaceMenu.new(reg)
      menu.open(v.scope, :common, ctx, subtabs: reg.has_section?(v.scope, :subtab))
      menu.activate(menu.entry_for('>')).should be_nil
      menu.level.should eq(family), v.id
      menu.verb_for('r').try(&.id).should eq(v.id)
    end
  end

  it "adds no band header to a menu that had none, and joins SEND where the bands exist" do
    reg = Gori::Verbs.registry
    {Gori::Verb::Scope::Repeater => :none, Gori::Verb::Scope::Fuzzer => :none, Gori::Verb::Scope::Miner => :none,
     Gori::Verb::Scope::Body => :send, Gori::Verb::Scope::HistoryDetail => :send,
     Gori::Verb::Scope::Sitemap => :send}.each do |scope, band|
      ctx = FakeExecContext.new
      ctx.selected = 5_i64
      menu = Gori::Tui::SpaceMenu.new(reg)
      menu.open(scope, :common, ctx, subtabs: reg.has_section?(scope, :subtab))
      menu.entry_for('>').not_nil!.group.should eq(band), scope.to_s
    end
  end

  it "leaves Active scan and Mock as direct rows" do
    %w[history.probe-active detail.probe-active repeater.probe-active probe.active-rescan
      history.mock-response detail.mock-response].each do |id|
      Gori::Verbs.registry[id].member?.should be_false, id
    end
  end
end
