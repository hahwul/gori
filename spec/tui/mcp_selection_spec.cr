require "../support/tui_contract"
require "../support/history_search"
require "json"

include Gori::Tui

# The operator's selection, as the four list tabs publish it into `ui_state` for
# `gori mcp get_current_context` (#1091).
#
# The contract these examples exist to hold: what goes on the wire is the ANSWER of the tab's
# own target rule — the marks if any are set, else the cursor row, else the flow an open
# detail pins — and never the inputs to it. An agent that had to re-derive "marks, else
# cursor" from a marked_ids/cursor_id pair would get it wrong in exactly the case the feature
# was built for.
private def selection_of(ctl : TabController) : JSON::Any
  JSON.parse(JSON.build { |j| ctl.write_mcp_selection(j) })
end

private def capture(store, target, host = "h.test", method = "GET", at = 1_i64)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: at, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
end

describe "History selection" do
  it "names the cursor row when nothing is marked, and the marks when something is" do
    TuiContract.with_session("sel-history") do |session|
      4.times { |i| capture(session.store, "/#{i}", at: 1_i64 + i) }
      session.store.flush
      ctl = HistoryController.new(TuiContract::Host.new(session))
      ctl.view.reload(session.store)
      settle_history(ctl)

      sel = selection_of(ctl)
      sel["kind"].as_s.should eq("flow")
      sel["target_source"].as_s.should eq("cursor")
      sel["ids"].as_a.size.should eq(1)
      sel["ids"].as_a.first.as_i64.should eq(ctl.view.selected_id)
      sel["marked_count"].as_i.should eq(0)
      sel["truncated"].as_bool.should be_false
      sel["visible_rows"].as_i.should eq(4)

      # `t` marks the cursor row and steps to the next OLDER flow, so two presses mark two.
      2.times { ctl.view.toggle_mark }
      sel = selection_of(ctl)
      sel["target_source"].as_s.should eq("marks")
      sel["marked_count"].as_i.should eq(2)
      sel["ids"].as_a.map(&.as_i64).should eq(ctl.view.target_ids)
      sel["primary_id"].as_i64.should eq(ctl.view.primary_target_id)
    end
  end

  it "moves `selection_ident` on every mark gesture — the whole reason the row gets rewritten" do
    TuiContract.with_session("sel-history-ident") do |session|
      4.times { |i| capture(session.store, "/#{i}", at: 1_i64 + i) }
      session.store.flush
      ctl = HistoryController.new(TuiContract::Host.new(session))
      ctl.view.reload(session.store)
      settle_history(ctl)

      # Each of these leaves active_tab / focus / subtab exactly where they were, which is
      # why the pre-#1091 identity tuple could not see any of them.
      before = ctl.selection_ident
      ctl.view.toggle_mark
      toggled = ctl.selection_ident
      toggled.should_not eq(before)

      ctl.view.mark_all
      marked_all = ctl.selection_ident
      marked_all.should_not eq(toggled)

      ctl.view.clear_marks
      ctl.selection_ident.should_not eq(marked_all)

      ctl.view.extend_marks(1)
      ctl.selection_ident.should_not eq(SelectionIdent.new)
    end
  end

  it "carries the narrowing the operator is looking at, so a big selection stays reproducible" do
    TuiContract.with_session("sel-history-query") do |session|
      capture(session.store, "/keep", host: "keep.test")
      capture(session.store, "/drop", host: "drop.test", at: 2_i64)
      session.store.flush
      ctl = HistoryController.new(TuiContract::Host.new(session))
      ctl.view.reload(session.store)
      settle_history(ctl)

      before = ctl.selection_ident
      ctl.view.set_query("host:keep.test")
      ctl.view.reload(session.store)
      settle_history(ctl, session.store)
      # A narrowing alone republishes: the ids may be identical and the CONTEXT is not.
      ctl.selection_ident.should_not eq(before)
      sel = selection_of(ctl)
      sel["query"].as_s.should eq("host:keep.test")
      sel["visible_rows"].as_i.should eq(1)
      sel["scope_lens"].as_bool.should be_false
    end
  end

  it "caps the named ids and SAYS it cut them, keeping the true count" do
    TuiContract.with_session("sel-history-cap") do |session|
      n = TabController::SELECTION_ID_CAP + 5
      n.times { |i| capture(session.store, "/#{i}", at: 1_i64 + i) }
      session.store.flush
      ctl = HistoryController.new(TuiContract::Host.new(session))
      ctl.view.reload(session.store)
      settle_history(ctl)
      ctl.view.mark_all

      sel = selection_of(ctl)
      sel["ids"].as_a.size.should eq(TabController::SELECTION_ID_CAP)
      sel["marked_count"].as_i.should eq(n)
      sel["truncated"].as_bool.should be_true
      sel["id_cap"].as_i.should eq(TabController::SELECTION_ID_CAP)
    end
  end

  it "collapses to the pinned flow while a detail is open, ignoring the marks" do
    TuiContract.with_session("sel-history-detail") do |session|
      4.times { |i| capture(session.store, "/#{i}", at: 1_i64 + i) }
      session.store.flush
      host = PinningHost.new(session)
      ctl = HistoryController.new(host)
      ctl.view.reload(session.store)
      settle_history(ctl)
      2.times { ctl.view.toggle_mark }

      host.pinned = 1_i64
      sel = selection_of(ctl)
      # Every detail verb acts on the pinned flow, so the published set has to as well —
      # otherwise an agent's "act on my selection" and the operator's own keys disagree.
      sel["target_source"].as_s.should eq("detail")
      sel["ids"].as_a.map(&.as_i64).should eq([1_i64])
      sel["primary_id"].as_i64.should eq(1_i64)
      # …and the marks are still REPORTED, so nothing looks lost.
      sel["marked_count"].as_i.should eq(2)
    end
  end
end

# A Host that can pin a detail flow, standing in for the Runner's `@detail_pin` / `@overlay`.
private class PinningHost < TuiContract::Host
  property pinned : Int64? = nil

  def detail_pinned_flow_id : Int64?
    @pinned
  end
end

describe "Sitemap selection" do
  it "reports {host, path} NODES and no `ids` key at all" do
    TuiContract.with_session("sel-sitemap") do |session|
      capture(session.store, "/dir/leaf", host: "a.test")
      capture(session.store, "/dir/other", host: "a.test", at: 2_i64)
      session.store.flush
      host = TuiContract::Host.new(session)
      host.tab = :target
      ctl = SitemapController.new(host)
      ctl.on_enter

      sel = selection_of(ctl)
      sel["kind"].as_s.should eq("sitemap_node")
      # An array whose element type depends on a sibling field is how a reader ends up doing
      # arithmetic on a hostname — so the integer key is ABSENT here, not empty.
      sel.as_h.has_key?("ids").should be_false
      sel["nodes"].as_a.each do |n|
        n.as_h.has_key?("host").should be_true
        n.as_h.has_key?("path").should be_true
      end
    end
  end
end

# `marks_elsewhere` is the answer to "I marked four, then walked somewhere else". Its skip
# rule is "this tab already published its marks", not "this tab is active" — Target is ONE
# registry tab over three children, and with Discover in front the parent publishes no
# selection at all.
describe "marks the selection block did not carry" do
  it "still names Sitemap's marks while the operator reads Discover beside them" do
    TuiContract.with_session("sel-target-discover") do |session|
      capture(session.store, "/dir/leaf", host: "a.test")
      capture(session.store, "/dir/other", host: "a.test", at: 2_i64)
      session.store.flush
      host = TuiContract::Host.new(session)
      host.tab = :target
      ctl = TargetController.new(host)
      ctl.on_enter
      ctl.sitemap.view.move(1)
      ctl.sitemap.view.toggle_mark
      ctl.sitemap.mcp_marked_count.should eq(1)

      # Sitemap in front: the parent publishes the selection, so the roll-up must not repeat it.
      ctl.mcp_selection?.should be_true
      ctl.selection_kind.should eq("sitemap_node")

      ctl.jump_subtab(1) # → Discover
      # Discover has no selection of its own AND cannot hold sub-tab marks (it never overrides
      # `subtab_ref`), so the parent now publishes nothing — and a plain active-tab skip in the
      # roll-up made four marked nodes vanish from both halves of the row.
      ctl.mcp_selection?.should be_false
      ctl.mcp_marked_count.should eq(1)
      # …and the label follows the child HOLDING the marks, never the one on screen.
      ctl.mcp_mark_kind.should eq("sitemap_node")
    end
  end
end

describe "Intercept selection" do
  it "publishes the hold filter under its own name, never as `query`" do
    TuiContract.with_session("sel-intercept") do |session|
      ctl = InterceptController.new(TuiContract::Host.new(session))
      sel = selection_of(ctl)
      sel["kind"].as_s.should eq("intercept_item")
      # This tab's `/` decides what gets HELD, not which held rows the list shows. Under the
      # name the other three tabs use for a list narrowing it would read as the latter.
      sel.as_h.has_key?("query").should be_false
      # Structural, not incidental: `prune_marks` keeps the mark set inside the live queue on
      # every refresh, so a mark is never off-window here.
      sel["marked_hidden_count"].as_i.should eq(0)
    end
  end
end

describe "the sub-tab strip's marks" do
  it "rides on the base class, so every strip-bearing tab reports them" do
    TuiContract.with_session("sel-subtabs") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      ctl.repeater_new
      ctl.toggle_subtab_mark(0)

      sel = selection_of(ctl)
      sel["marked_subtabs"].as_a.map(&.["subtab"].as_i).should eq([0])
      sel["marked_subtab_count"].as_i.should eq(1)
      # The strip's marks move the identity too — otherwise marking a chip publishes nothing.
      ctl.selection_ident.subtabs.should eq(1)
    end
  end

  it "never calls the ACTIVE chip marked when the mark set prunes to empty" do
    TuiContract.with_session("sel-subtabs-prune") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      ctl.repeater_new
      # A mark on a view that is no longer on the strip — what a peer's `delete_repeater`
      # leaves behind. `target_subtab_indices` falls back to the ACTIVE chip here, so reading
      # it would have told an agent the session the operator happens to have open is marked.
      ctl.toggle_subtab_mark(0)
      ctl.close_subtab_at(0)
      ctx = JSON.parse(JSON.build { |j| ctl.write_mcp_context(j) })
      ctx.as_h.has_key?("marked_db_ids").should be_false
      selection_of(ctl).as_h.has_key?("marked_subtabs").should be_false
    end
  end

  it "leaves repeater ADDRESSING to the repeater block, which speaks db_ids" do
    TuiContract.with_session("sel-subtabs-ids") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      ctl.toggle_subtab_mark(0)

      # The generic block can only carry chip numbers (SubtabMarks keys on view identity), so
      # it must not also try to catalogue the strip — there is one home for repeater ids.
      selection_of(ctl).as_h.has_key?("marked_db_ids").should be_false
      ctx = JSON.parse(JSON.build { |j| ctl.write_mcp_context(j) })
      ctx.as_h.has_key?("marked").should be_false
    end
  end
end
