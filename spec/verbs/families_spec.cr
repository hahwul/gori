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

# A menu opened on `scope`/`section` the way the Runner opens it, descended into `family`.
private def family_card(scope : Gori::Verb::Scope, section : Symbol, ctx : FakeExecContext,
                        family : Gori::Verb::Family) : Gori::Tui::SpaceMenu
  reg = Gori::Verbs.registry
  menu = Gori::Tui::SpaceMenu.new(reg)
  menu.open(scope, section, ctx, subtabs: reg.has_section?(scope, :subtab))
  menu.activate(menu.entry_for(family.key)).should be_nil
  menu.level.should eq(family)
  menu
end

private def members_of(family : Gori::Verb::Family) : Array(String)
  Gori::Verbs.registry.select { |v| v.family == family.id && !v.hidden? }.map(&.id).sort!
end

describe "Display… and Protocol… (#1274 WP9)" do
  display = Gori::Verbs::DISPLAY
  protocol = Gori::Verbs::PROTOCOL

  it "are registered, sticky, on `Z` and `P`" do
    reg = Gori::Verbs.registry
    reg.family(:display).should eq(display)
    reg.family(:protocol).should eq(protocol)
    {display, protocol}.each(&.sticky?.should(be_true))
    display.key.should eq('Z')
    display.group.should eq(:view)
    protocol.key.should eq('P')
  end

  it "gives each member intent the same level-2 letter in every scope that has it" do
    reg = Gori::Verbs.registry
    {display, protocol}.each do |family|
      family.intents.each do |intent|
        found = reg.select { |v| v.family == family.id && v.intent == intent }
        found.should_not be_empty, intent.to_s
        found.map { |v| reg.l2_key(v) }.uniq!.should eq([family.letter(intent)]), intent.to_s
      end
    end
  end

  # Display toggles only: a write-back (pretty-print-request, pretty-print-template) changes
  # the request, not the view, and the Fuzzer's sort stays a direct row for results triage.
  it "holds the display toggles and nothing that rewrites the request" do
    members_of(display).should eq(%w[
      comparer.toggle-fold comparer.toggle-pane detail.toggle-hex detail.toggle-pretty
      detail.toggle-unicode detail.toggle-ws fuzz.dist fuzz.matched history.columns
      history.toggle-follow history.toggle-static repeater.toggle-diff repeater.toggle-envelope
      repeater.toggle-hex repeater.toggle-pretty repeater.toggle-resp-hex repeater.toggle-unicode
      sitemap.toggle-grouping sitemap.toggle-js-refs sitemap.toggle-query-fold sitemap.toggle-static
    ])
    reg = Gori::Verbs.registry
    %w[repeater.pretty-request fuzz.pretty-template repeater.toggle-decoded].each do |id|
      reg[id].member?.should be_false, id
    end
    reg["fuzz.sort"].menu_key.should eq('o')
  end

  it "holds the Repeater's and the Fuzzer's transport settings" do
    members_of(protocol).should eq(%w[
      fuzz.toggle-http2 fuzz.toggle-sni repeater.cycle-tls-preset repeater.toggle-auto-content-length
      repeater.toggle-grpc-fields repeater.toggle-grpc-reframe repeater.toggle-http2
      repeater.toggle-sni repeater.toggle-ws-key
    ])
    # Save results left `P` for the family; it is palette-only now (#1282), on its `⇧E` (#1295).
    Gori::Verbs.registry["fuzz.save-results"].palette_only?.should be_true
  end

  it "reaches hex with `Z x` in the History detail and both Repeater panes" do
    detail = FakeExecContext.new
    detail.selected = 5_i64
    family_card(Gori::Verb::Scope::HistoryDetail, :common, detail, display).verb_for('x').try(&.id).should eq("detail.toggle-hex")
    rep = FakeExecContext.new
    rep.current_tab = :repeater
    rep.repeater_tab_count = 1
    family_card(Gori::Verb::Scope::Repeater, :request, rep, display).verb_for('x').try(&.id).should eq("repeater.toggle-hex")
    family_card(Gori::Verb::Scope::Repeater, :response, rep, display).verb_for('x').try(&.id).should eq("repeater.toggle-resp-hex")
  end

  it "reaches HTTP/2 and SNI with the same keys on the Repeater and the Fuzzer" do
    {Gori::Verb::Scope::Repeater => {:repeater, :request, "repeater"},
     Gori::Verb::Scope::Fuzzer   => {:fuzzer, :template, "fuzz"}}.each do |scope, (tab, pane, prefix)|
      ctx = FakeExecContext.new
      ctx.current_tab = tab
      family_card(scope, pane, ctx, protocol).verb_for('2').try(&.id).should eq("#{prefix}.toggle-http2")
      family_card(scope, :target, ctx, protocol).verb_for('s').try(&.id).should eq("#{prefix}.toggle-sni")
    end
  end

  # ^T drops a § marker on a tab with no split, so the menu row is its own verb, listed only
  # where there is an envelope to switch.
  it "lists the envelope row only on a tab that splits its request" do
    ctx = FakeExecContext.new
    ctx.current_tab = :repeater
    family_card(Gori::Verb::Scope::Repeater, :request, ctx, display).verb_for('e').should be_nil
    ctx.repeater_split_request = true
    family_card(Gori::Verb::Scope::Repeater, :request, ctx, display).verb_for('e').try(&.id).should eq("repeater.toggle-envelope")
    Gori::Verbs.registry["repeater.toggle-decoded"].menu_key.should be_nil
  end

  # WP2 #5: the detail's "Copy flow" copied the raw request, which Copy as… already offers.
  it "leaves the detail's raw-request copy to Copy as…" do
    Gori::Verbs.registry["detail.copy-flow"]?.should be_nil
    Gori::Verbs.registry["detail.copy-as"].menu_key.should eq('Y')
    opts = Gori::Tui::CopyMenu.request_options("GET /a HTTP/1.1\r\nHost: x.test\r\n\r\n", "http://x.test")
    opts.find { |o| o.key == 'r' }.try(&.label).should eq("Raw request")
  end
end
