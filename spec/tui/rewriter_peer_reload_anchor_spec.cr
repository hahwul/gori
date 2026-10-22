require "../spec_helper"
require "../support/fake_host"
require "file_utils"
require "../../src/gori/tui/controllers/rewriter_controller"

include Gori::Tui

# The Rewriter tab's rule list moves under the cursor now, and it did not used to.
#
# `Rules`/`Bindings` were refreshed only on tab entry and on the tab's own `r`, so the list an
# operator was looking at could not change while they looked at it. Making a peer's rule reach
# the live proxy objects put `rules.reload` on the `data_version` tick — which fires while this
# tab is on screen — and the tab renders `rules_engine.rules` directly, so an agent's
# `create_rule`/`delete_rule` now reorders the rows under the highlight.
#
# `@sel` is a positional index. A peer deleting the row above the cursor slides a different rule
# into it, and the next key the operator presses (`space` to toggle, `d` to delete, `↵` to edit)
# reads `selected_rule` — so the action lands on a rule they never selected. `IssuesView` already
# solved exactly this and says why in `apply_filter`: "re-anchor selection by issue id (not
# index) so a data_version reload under live capture doesn't jump the highlight to a different
# row." This is that, for the three lists this tab reloads.

private REWRITER_ANCHOR_CA = File.tempname("gori-rewriter-anchor-ca")
Spec.after_suite { FileUtils.rm_rf(REWRITER_ANCHOR_CA) }

private def with_anchor_controller(&)
  root = File.tempname("gori-rewriter-anchor")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("rewriteranchor")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(REWRITER_ANCHOR_CA), Gori::Verbs.registry, project)
  begin
    yield RewriterController.new(FakeHost.new(session, :rewriter)), session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# Project-scope rules, so the peer edit is a row in THIS project's store — the shape MCP
# `create_rule`/`delete_rule` and a second TUI both produce, with no settings.json in play.
private def add_rule(session : Gori::Session, name : String) : Int64
  session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
    "pattern-#{name}", "x", name: name)
  session.rules.rules.find! { |r| r.name == name }.id
end

# The public way the operator's cursor gets anywhere but row 0.
private def move_to(ctl : RewriterController, index : Int32) : Nil
  index.times { ctl.handle_wheel(1) }
end

describe "the Rewriter rule list under a peer's edit" do
  it "keeps the highlight on the SAME rule when a peer deletes the row above it" do
    with_anchor_controller do |ctl, session|
      add_rule(session, "first")
      add_rule(session, "second")
      third = add_rule(session, "third")
      ctl.on_enter
      move_to(ctl, 2)
      ctl.selected_rule.not_nil!.id.should eq(third)

      # The peer deletes the top rule; every row below it slides up one index.
      session.store.delete_rule(session.rules.rules.first.id)
      ctl.on_external_change

      # Index 2 no longer exists at all, and index 1 is now a rule the operator never chose.
      ctl.selected_rule.not_nil!.id.should eq(third)
    end
  end

  it "keeps it when a peer INSERTS above the cursor too" do
    with_anchor_controller do |ctl, session|
      first = add_rule(session, "first")
      add_rule(session, "second")
      ctl.on_enter
      ctl.selected_rule.not_nil!.id.should eq(first) # cursor on row 0

      # Through a SEPARATE `Rules` over the same store, which is what makes this a peer edit:
      # this session's live object stays stale until the tick reloads it, exactly as it would
      # be while another process did the writing. Going through `session.rules` instead would
      # mutate the very list the anchor is read from and test nothing.
      peer = Gori::Rules.load(session.store)
      peer.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "pattern-peer", "x",
        name: "peer")
      added = peer.rules.find! { |r| r.name == "peer" }
      # `add` appends, so the peer reorders it to the top — the same list movement a scope
      # change or ⇧K produces.
      2.times { peer.move(added.id, -1, added.scope) }
      session.rules.rules.first.name.should eq("first") # still stale here, by construction

      ctl.on_external_change

      ctl.selected_rule.not_nil!.id.should eq(first)
    end
  end

  it "falls back to the index when the peer deleted the very rule under the cursor" do
    # Nothing to anchor to. Staying at the same index leaves the operator where they were in
    # the list, which beats snapping to the top of it.
    with_anchor_controller do |ctl, session|
      add_rule(session, "first")
      second = add_rule(session, "second")
      third = add_rule(session, "third")
      ctl.on_enter
      move_to(ctl, 1)
      ctl.selected_rule.not_nil!.id.should eq(second)

      session.store.delete_rule(second)
      ctl.on_external_change

      ctl.selected_rule.not_nil!.id.should eq(third) # index 1, which is now "third"
    end
  end

  it "clamps rather than pointing past the end when a peer empties the list" do
    with_anchor_controller do |ctl, session|
      add_rule(session, "first")
      add_rule(session, "second")
      ctl.on_enter
      move_to(ctl, 1)

      session.rules.rules.each { |r| session.store.delete_rule(r.id) }
      ctl.on_external_change

      ctl.selected_rule.should be_nil # nothing to select, and nothing raised getting there
    end
  end

  it "anchors the extract sub-tab the same way" do
    # `bindings.reload` is on the same tick, and `@sub_sel` indexes it. The extract rules decide
    # what `$KEY` expands to at every send seam, so a delete landing on the wrong one is a live
    # rewrite the operator did not ask for.
    with_anchor_controller do |ctl, session|
      session.bindings.add("alpha", "", Gori::ExtractKind::Header, "X-A")
      session.bindings.add("beta", "", Gori::ExtractKind::Header, "X-B")
      session.bindings.add("gamma", "", Gori::ExtractKind::Header, "X-C")
      ctl.on_enter
      # ⇥ (the focus ring's `pane_advance`) moves to the extract section; the wheel then walks
      # the sub list, both public entry points.
      ctl.pane_advance(1)
      ctl.handle_wheel(1)
      ctl.handle_wheel(1)
      gamma = session.bindings.rules.find! { |r| r.name == "gamma" }.id
      ctl.selected_extract_rule.not_nil!.id.should eq(gamma)

      session.store.delete_extract_rule(session.bindings.rules.first.id)
      ctl.on_external_change

      ctl.selected_extract_rule.not_nil!.id.should eq(gamma)
    end
  end
end
