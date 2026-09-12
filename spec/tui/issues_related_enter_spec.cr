require "../spec_helper"
require "file_utils"
require "../support/fake_host"
require "../support/overlay_harness"
require "../../src/gori/tui/controllers/issues_controller"

include Gori::Tui

# ↵ on an Issue's RELATED row SHOWS that row's exchange in place; `s` goes to its source.
#
# One key, one action. ↵ used to mean two things in ONE list — a LIVE row teleported to
# History/Repeater/Fuzzer/Miner, a FROZEN row opened a modal — so what the key did depended on
# a badge two columns to its left. The Evidence tab already had the grammar (`↵ open · s
# source`) and RELATED now matches it.
#
# `Runner.new` owns a terminal and appears nowhere under spec/ (see the note in
# `evidence_drift_confirm_spec.cr`), so the behaviour is driven where it actually lives: the
# card through `EvidenceViewer`, the sentences through `Runner.live_view_refusal` and the
# Store's own predicates, the hint strip through `IssuesController`, and the branching between
# them by reading the source with comments stripped — a comment explaining a rule contains the
# tokens the rule looks for.
private def runner_evidence_code : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "evidence.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def method_body(name : String) : String
  runner_evidence_code[/(private )?def #{Regex.escape(name)}.*?\n  end/m].not_nil!
end

private ENTER_CA = File.tempname("gori-related-enter-ca")
Spec.after_suite { FileUtils.rm_rf(ENTER_CA) }

private def with_issues_tab(&)
  root = File.tempname("gori-related-enter")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("relatedenter")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(ENTER_CA), Gori::Verbs.registry, project)
  begin
    yield Gori::Tui::IssuesController.new(FakeHost.new(session)), session.store
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def captured(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "POST", target: target, http_version: "HTTP/1.1",
    head: "POST #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    body: "u=a&p=b".to_slice, source: Gori::FlowSource::Kind::Proxy)
end

private def answered_flow(store, target : String) : Int64
  fid = store.insert_flow(captured(target))
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, 200, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    "welcome".to_slice, duration_us: 4_200_i64))
  fid
end

private def link(store, issue : Int64, kind : Gori::Store::LinkRefKind, id : Int64) : Nil
  store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, kind, id)
end

# The detail open on its first issue, its RELATED rows built as `Links.resolve_all` builds
# them for the card.
private def selected(store) : IssuesView
  view = IssuesView.new
  view.reload(store)
  view.open_detail(store).should be_true
  view
end

describe "↵ on a RELATED row" do
  # The whole point: for a LIVE flow the key produces a CARD, not a tab change. The bytes on it
  # are the flow's as it stands, which is what `Evidence.snapshot_for` — the builder the freeze
  # itself uses — hands back, so what ↵ shows and what `f` would keep cannot drift apart.
  it "shows a live flow's exchange in place, titled LIVE, with the flow's bytes" do
    with_store do |store|
      fid = answered_flow(store, "/login")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      link(store, issue, Gori::Store::LinkRefKind::Flow, fid)

      view = selected(store)
      res = view.selected_resolved_link.not_nil!
      res.stale?.should be_false
      Gori::Evidence.freezable?(res.link.ref_kind).should be_true

      snap = Gori::Evidence.snapshot_for(store, res.link.ref_kind, res.link.ref_id)
      snap = snap.as(Gori::Evidence::Snapshot)
      v = EvidenceViewer.new(snap)
      h = OverlayHarness.new(v, area: Rect.new(0, 0, 160, 30))
      v.title.should eq("LIVE hist ##{fid}")
      h.rendered?("POST /login HTTP/1.1").should be_true
      h.rendered?("as it is now").should be_true
      h.rendered?("not frozen").should be_true
      v.show(:response)
      h.rendered?("welcome").should be_true
    end
  end

  # …and the Runner routes ↵ there rather than to `navigate_link_ref`, which is what it used to
  # do for exactly this row. A freezable live row NEVER reaches the navigation arm.
  it "routes a live freezable row to the viewer and a session row to the navigation" do
    body = method_body("issue_open_link")
    body.should contain("open_live_evidence_viewer(res)")
    # The navigation survives on precisely two arms: a stale row (nothing to show) and a fuzz
    # or miner session (no single exchange to show). Read off `Evidence.freezable?`, the same
    # predicate the hint strip and the freeze gate read, so the three cannot disagree.
    body.should contain("res.stale? || !Evidence.freezable?(res.link.ref_kind)")
    body.index("navigate_link_ref").not_nil!.should be < body.index("open_live_evidence_viewer").not_nil!
    # A FROZEN row still opens its copy, and that arm comes first — it is the one row kind
    # whose exchange exists independently of any live source.
    body.index("open_evidence_viewer(m.id)").not_nil!.should be < body.index("navigate_link_ref").not_nil!
  end

  # A fuzz/miner session is the honest exception: a template plus a run has no single exchange
  # to put on a card, so ↵ opens the session and the hint says `↵ open session` instead of
  # `↵ view`.
  it "leaves a fuzz session to the navigation, because it has no one exchange" do
    with_store do |store|
      sid = store.insert_fuzz_session("https://acme.test", "GET /FUZZ HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0)
      issue = store.insert_issue("fuzz finding", Gori::Store::Severity::Low, "acme.test", nil)
      link(store, issue, Gori::Store::LinkRefKind::Fuzz, sid)

      view = selected(store)
      res = view.selected_resolved_link.not_nil!
      res.link.ref_kind.fuzz?.should be_true
      Gori::Evidence.freezable?(res.link.ref_kind).should be_false
      # And there is nothing a viewer could be built from, in the shared builder's own words.
      Gori::Evidence.snapshot_for(store, res.link.ref_kind, res.link.ref_id)
        .should eq("only a flow or a repeater exchange can be frozen (fuzz sessions have no single exchange)")
    end
  end

  # A Repeater tab that was linked before it was ever sent has a row and no exchange. ↵ says
  # so — and says it with the advice THIS key can give, because `snapshot_for`'s own sentence
  # advises freezing and ↵ is a read.
  it "toasts a never-sent repeater with the fact, re-pointed at `s`" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test", "GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      sentence = Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Repeater, rid)
      sentence.should eq("repeater ##{rid} has never been sent — send it first, then freeze the exchange")

      Runner.live_view_refusal(Gori::Store::LinkRefKind::Repeater, rid, sentence.as(String), true, "s")
        .should eq("repeater ##{rid} has never been sent — s opens the tab")
      # A flow whose response has not landed keeps the same shape, pointed at its own tab.
      Runner.live_view_refusal(Gori::Store::LinkRefKind::Flow, 7_i64,
        "flow #7 has no response yet — wait for it to complete, then freeze the exchange", true, "s")
        .should eq("flow #7 has no response yet — s opens it in History")
      # …and a source that is GONE keeps `snapshot_for`'s sentence whole: there is nothing
      # behind either key, and offering one would be a lie about a pruned row.
      pruned = "no flow with id 9 — it may have been pruned"
      Runner.live_view_refusal(Gori::Store::LinkRefKind::Flow, 9_i64, pruned, false, "s").should eq(pruned)
    end
  end

  # The card the live path opens copies through the ambient body-redaction policy (#1035), the
  # way the frozen card already did — the clipboard leaves the project either way.
  it "copies the live pane through the redaction policy, not the raw bytes" do
    body = method_body("open_live_evidence_viewer")
    body.should contain("sanitized_snapshot(snap)")
    body.should contain("snapshot_pane_text(clean, viewer.pane)")
    body.should contain("SANITIZED")
    # `f` is armed on the live card only, and its landing flips the card rather than closing it.
    body.should contain("viewer.on_freeze")
    method_body("freeze_from_live_viewer").should contain("viewer.frozen_as(ev)")
  end
end

describe "`s` on a RELATED row" do
  it "goes to the live row's own tab — today's ↵, on its own key now" do
    goto = method_body("issue_goto_link")
    goto.should contain("navigate_link_ref(res.link.ref_kind, res.link.ref_id)")
    # Available on every row a cursor can sit on: each kind HAS a source tab, and the ones that
    # cannot be reached answer with the reason rather than with nothing.
    method_body("issue_related_goto?").should contain("selected_related")
  end

  # A frozen copy outlives the tab it came from, and `repeaters.id` has no AUTOINCREMENT — so a
  # tab opened afterwards can inherit the id. `s` must refuse rather than present a stranger as
  # the original (#1048); the wiring order is pinned in evidence_source_reuse_spec.
  it "refuses a FROZEN row whose repeater id was reused" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater_response(rid, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "a".to_slice, nil, 1_i64,
        request_sha256: nil)
      issue = store.insert_issue("t", Gori::Store::Severity::Low, nil, nil)
      snap = Gori::Evidence.from_repeater(store.get_repeater_full(rid).not_nil!).not_nil!
      eid, status = store.freeze_evidence(issue, snap)
      status.ok?.should be_true
      store.delete_repeater(rid).should be_true
      reused = store.insert_repeater("https://other.test", "GET /b HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      reused.should eq(rid)

      meta = store.get_evidence(eid).not_nil!.meta
      store.get_repeater(meta.source_id).should_not be_nil # the id resolves…
      store.evidence_source_alive?(meta).should be_false   # …and is not this copy's tab
      Runner::EVIDENCE_SOURCE_REUSED.should contain("its id was reused")
    end
  end
end

describe "the RELATED hint strip" do
  # The strip names what the keys under your fingers DO on the row under the cursor. Every
  # token follows the drop-or-swap rule the `f` token already followed: never promise a key the
  # verb would refuse, and never name an action the row cannot take.
  it "says `↵ view · s source` on a live flow, with `f freeze` beside them" do
    with_issues_tab do |ctl, store|
      fid = answered_flow(store, "/login")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      link(store, issue, Gori::Store::LinkRefKind::Flow, fid)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true

      hint = ctl.body_hint(:body)
      hint.should contain("↵ view")
      hint.should contain("s source")
      hint.should contain("f freeze")
      hint.should_not contain("↵ open session")
    end
  end

  it "swaps in `↵ open session` on a fuzz row, where there is no exchange to view" do
    with_issues_tab do |ctl, store|
      sid = store.insert_fuzz_session("https://acme.test", "GET /FUZZ HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0)
      issue = store.insert_issue("fuzz finding", Gori::Store::Severity::Low, "acme.test", nil)
      link(store, issue, Gori::Store::LinkRefKind::Fuzz, sid)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true

      hint = ctl.body_hint(:body)
      hint.should contain("↵ open session")
      hint.should contain("s source")
      # Nothing to freeze on a session row — the token that was already gated stays gone.
      hint.should_not contain("f freeze")
    end
  end

  it "drops `s source` when RELATED has no row under the cursor" do
    with_issues_tab do |ctl, store|
      store.insert_issue("bare", Gori::Store::Severity::Low, nil, nil)
      ctl.view.reload(store)
      ctl.view.open_detail(store).should be_true
      ctl.view.related_rows.should be_empty

      hint = ctl.body_hint(:body)
      hint.should_not contain("s source")
      hint.should_not contain("f freeze")
    end
  end
end
