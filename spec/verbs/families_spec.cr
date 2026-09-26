require "../spec_helper"
require "../support/fake_context"
require "../support/memory_backend"
require "../support/tui_contract"

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

  # A bare `>` is the family's own key without the `space` (#1295): bound in every scope that
  # has a member, to a hidden verb whose one intent is to open this card, and nowhere Global,
  # so on a tab without the family it stays unbound instead of reaching something else.
  it "binds a bare `>` to this card in every scope that has a member, and nowhere else" do
    reg = Gori::Verbs.registry
    family.chord.should eq(Gori::Verb::Chord.new(">"))
    chord = family.chord.not_nil!
    with_members = reg.compact_map { |v| v.scope if v.family == family.id && !v.hidden? }.to_set
    with_members.should contain(Gori::Verb::Scope::Params) # Mine parameters joined (#1295)
    Gori::Verb::OsProfile::Os.each do |os|
      Gori::Verb::Keyset::Kind.each do |ks|
        km = Gori::Verb::Keymap.build(reg, os, Gori::Verb::Keymap::NO_OVERRIDES, ks)
        km.lookup_in(chord, Gori::Verb::Scope::Global).should be_nil
        km.lookup_in(chord, Gori::Verb::Scope::Editor).should be_nil
        Gori::Verb::Scope.each do |scope|
          id = km.lookup_in(chord, scope)
          if with_members.includes?(scope)
            id.should_not be_nil, scope.to_s
            reg.opens_family(id.not_nil!).should eq(family.id)
          else
            id.should be_nil, scope.to_s
          end
        end
      end
    end
    with_members.each do |scope|
      opener = reg.find! { |v| v.scope == scope && reg.opens_family(v.id) == family.id }
      opener.hidden?.should be_true # no row, no palette entry: it IS the family row's key
      ctx = FakeExecContext.new
      opener.call(ctx)
      ctx.calls.should eq([FakeExecContext::Call.new(:open_space_family, ["send_flow"])])
    end
  end

  it "lands the bare `>` in the card `space >` opens, on every tab that binds it" do
    # `Runner#open_space_family` is `open_space_menu` + `SpaceMenu#descend`; the descent is
    # what must hold in each scope, from the view `space` would have opened.
    reg = Gori::Verbs.registry
    reg.select { |v| reg.opens_family(v.id) == family.id }.each do |opener|
      ctx = FakeExecContext.new
      ctx.selected = 5_i64
      menu = Gori::Tui::SpaceMenu.new(reg)
      menu.open(opener.scope, :common, ctx, subtabs: reg.has_section?(opener.scope, :subtab))
      menu.descend(family).should be_true, opener.scope.to_s
      menu.card_title.should start_with("SPACE › SEND FLOW TO")
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

# Help and the Project settings pane once borrowed History's Body scope, so the family rows
# (static: drawn whenever the scope registers a member) and the bare `>` opened dead cards on
# them. Each pane owns its keys, and its scope registers nothing: space says "no commands for
# this area" there, and `>` is unbound.
describe "a pane that owns its keys (Help, Project settings)" do
  it "draws no row and binds no `>`, from the pane or from the tab bar" do
    reg = Gori::Verbs.registry
    keymap = Gori::Verb::Keymap.build(reg)
    scopes = {} of Symbol => Gori::Verb::Scope
    TuiContract.with_session("owned-keys") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        case controller
        when Gori::Tui::HelpController
          scopes[:help] = controller.command_scope
        when Gori::Tui::ProjectController
          controller.jump_subtab(Gori::Tui::ProjectView::PANES.index!(:settings))
          scopes[:project] = controller.command_scope
        end
      end
    end
    scopes.should eq({:help => Gori::Verb::Scope::Help, :project => Gori::Verb::Scope::ProjectSettings})
    scopes.each do |tab, scope|
      reg.none? { |v| v.scope == scope }.should be_true, scope.to_s
      ctx = FakeExecContext.new
      ctx.current_tab = tab
      ctx.selected = 5_i64
      {:body, :menu}.each do |focus|
        here = Gori::Tui::ActionContext.capture(reg, detail: false, focus: focus, scope: scope, pane_section: :common)
        menu = Gori::Tui::SpaceMenu.new(reg)
        menu.open(here.scope, here.section, ctx, subtabs: here.subtabs)
        menu.entries.should be_empty, "#{scope} (#{focus})"
      end
      keymap.lookup(Gori::Verb::Chord.new(">"), scope).should be_nil
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

  # Without its own bare key a family's `Z`/`P` did nothing on a dropped `space`, and the
  # member letter behind it was read bare: `Z c` (Columns…) stopped capture on History and
  # `P 2` (HTTP/2) jumped to the second tab. The key now opens the card, as `>` does.
  it "binds a bare `⇧Z`/`⇧P` to its card in every scope that has a member, and nowhere else" do
    reg = Gori::Verbs.registry
    display.chord.should eq(Gori::Verb::Chord.new("z", shift: true))
    protocol.chord.should eq(Gori::Verb::Chord.new("p", shift: true))
    {display, protocol}.each do |family|
      chord = family.chord.not_nil!
      with_members = reg.compact_map { |v| v.scope if v.family == family.id && !v.hidden? }.to_set
      Gori::Verb::OsProfile::Os.each do |os|
        Gori::Verb::Keyset::Kind.each do |ks|
          km = Gori::Verb::Keymap.build(reg, os, Gori::Verb::Keymap::NO_OVERRIDES, ks)
          km.lookup_in(chord, Gori::Verb::Scope::Global).should be_nil
          km.lookup_in(chord, Gori::Verb::Scope::Editor).should be_nil
          with_members.each do |scope|
            id = km.lookup_in(chord, scope)
            id.should_not be_nil, "#{family.id} #{scope}"
            reg.opens_family(id.not_nil!).should eq(family.id)
          end
        end
      end
      reg.select { |v| reg.opens_family(v.id) == family.id }.each do |opener|
        opener.hidden?.should be_true
        with_members.should contain(opener.scope)
        ctx = FakeExecContext.new
        opener.call(ctx)
        ctx.calls.should eq([FakeExecContext::Call.new(:open_space_family, [family.id.to_s])])
      end
    end
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
      history.toggle-follow history.toggle-static params.all-headers probe.toggle-closed repeater.toggle-diff repeater.toggle-envelope
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

  # `^X` toggles the hex of the focused pane, so the response pane's row names it too
  # (`chord_of:`, #1295) — it had no key on screen, although the chord always worked there.
  it "shows ^X beside hex in the response pane's card" do
    rep = FakeExecContext.new
    rep.current_tab = :repeater
    rep.repeater_tab_count = 1
    card = family_card(Gori::Verb::Scope::Repeater, :response, rep, display)
    backend = MemoryBackend.new(80, 30)
    card.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 80, 28))
    row = (0...30).map { |y| backend.row(y) }.find!(&.includes?("Hex dump"))
    row.should contain("^X")
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
