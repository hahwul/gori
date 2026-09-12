require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The primary flow is the FIRST RELATED row.
#
# An Issue relates to traffic four ways — `issues.flow_id`, entity links, frozen evidence,
# retest steps — and the operator sees ONE question: what backs this issue. So the flow it
# was filed from stopped being a thing of its own: no `flow  GET … → 200` meta row above the
# card, no `- **Flow:**` bullet above the report's Related list. It is row one of RELATED,
# badged LIVE like any other pointer, and `s` on it goes where the removed `o` went.
#
# `flow_id` stays in the schema: it is the seed `insert_issue` links from, the source of
# SARIF's `webRequest`, and what `--flow` / `create_issue(flow_id:)` / Probe write.

private def captured(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
end

private def answered_flow(store, target : String) : Int64
  fid = store.insert_flow(captured(target))
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, 200, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "hi".to_slice, duration_us: 7_i64))
  fid
end

private def detail(store) : IssuesView
  view = IssuesView.new
  view.reload(store)
  view.open_detail(store).should be_true
  view
end

private def render(view, w = 100, h = 22) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h), focused: true)
  backend
end

# `Runner.new` owns a terminal and appears nowhere under spec/, so the Runner's own branching
# is read off the source with comments stripped — the convention issues_related_enter_spec
# established for the ↵/`s` pair this key sits beside.
private def runner_code(file : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "#{file}.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def method_body(file : String, name : String) : String
  runner_code(file)[/(private )?def #{Regex.escape(name)}.*?\n  end/m].not_nil!
end

describe "an issue's primary flow in RELATED" do
  it "is row one, ahead of the links added after it" do
    with_store do |store|
      primary = answered_flow(store, "/login")
      extra = answered_flow(store, "/admin")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", primary)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, Gori::Store::LinkRefKind::Flow, extra)

      view = detail(store)
      rows = view.related_rows
      rows.size.should eq(2)
      rows[0].live.not_nil!.link.ref_id.should eq(primary)
      rows[1].live.not_nil!.link.ref_id.should eq(extra)
      # The cursor opens on it, so ↵/`s`/`f`/`r` all act on the primary flow by default.
      view.selected_resolved_link.not_nil!.link.ref_id.should eq(primary)
    end
  end

  # An OLD-STYLE issue: `flow_id` set, its link row gone — an issue filed before the
  # entity_links migration, an imported project, a link dropped by SQL. The row is synthesised,
  # so nothing the issue names disappears from the card. (A PRUNED flow is not this shape:
  # `delete_flows` nulls `issues.flow_id` with the link, so there is no primary left to show.)
  it "still shows the flow when its link row was deleted by hand" do
    with_store do |store|
      primary = answered_flow(store, "/legacy")
      issue = store.insert_issue("old finding", Gori::Store::Severity::Medium, "acme.test", primary)
      link = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue)[0]
      store.remove_link(link.id).should be_true

      view = detail(store)
      view.related_rows.size.should eq(1)
      row = view.related_rows[0]
      row.frozen?.should be_false
      row.live.not_nil!.link.ref_id.should eq(primary)
      rel, _ = view.detail_split(Rect.new(0, 0, 100, 22))
      render(view).row(rel.y + 1).should contain("GET acme.test/legacy")
    end
  end

  # The order a create lands in: the primary (linked by `insert_issue` itself), then the
  # marked extras `create_issue_from_form` adds, then the frozen copies it writes last.
  it "orders a multi-flow create primary → extras → frozen" do
    with_store do |store|
      primary = answered_flow(store, "/one")
      extra = answered_flow(store, "/two")
      issue = store.insert_issue("multi", Gori::Store::Severity::High, "acme.test", primary)
      store.add_links(Gori::Store::LinkOwnerKind::Issue, issue,
        [{Gori::Store::LinkRefKind::Flow, extra}]).should eq(1)
      snap = Gori::Evidence.from_flow(store.get_flow(primary).not_nil!)
      store.freeze_evidence(issue, snap)[1].ok?.should be_true

      rows = detail(store).related_rows
      rows.size.should eq(3)
      rows[0].live.not_nil!.link.ref_id.should eq(primary)
      rows[1].live.not_nil!.link.ref_id.should eq(extra)
      rows[2].frozen?.should be_true
    end
  end

  # …and that IS the order the form writes in: the insert links the primary, the extras are
  # added after it, the snapshots land last.
  it "writes a create in that order" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    body = src[/private def create_issue_from_form.*?\n    end/m].not_nil!
    insert = body.index("insert_issue").not_nil!
    extras = body.index("add_links").not_nil!
    frozen = body.index("write_form_snapshots").not_nil!
    insert.should be < extras
    extras.should be < frozen
  end

  it "has no `flow` meta row left above the card" do
    with_store do |store|
      primary = answered_flow(store, "/only")
      store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", primary)
      view = detail(store)
      backend = render(view)
      rel, _ = view.detail_split(Rect.new(0, 0, 100, 22))
      rel.y.should eq(3) # title, chips, timestamps — and nothing else
      (0...rel.y).each { |y| backend.row(y).should_not contain("flow      ") }
    end
  end
end

describe "`r` on the Issues detail" do
  # The cursor row when it carries a request this key can duplicate…
  it "takes a FROZEN row under the cursor" do
    with_store do |store|
      src = answered_flow(store, "/frozen")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", nil)
      eid, status = store.freeze_evidence(issue, Gori::Evidence.from_flow(store.get_flow(src).not_nil!))
      status.ok?.should be_true

      view = detail(store)
      view.related_rows.size.should eq(1)
      view.repeater_target_row.not_nil!.frozen.not_nil!.id.should eq(eid)
    end
  end

  # …and the first flow row when it does not. A fuzz session is a template plus a run with no
  # single exchange; `r` falls back rather than refusing, because that is what it meant before
  # it looked at the cursor at all.
  it "falls back to the first flow row from a fuzz row" do
    with_store do |store|
      primary = answered_flow(store, "/one")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", primary)
      sid = store.insert_fuzz_session("https://acme.test", "GET /FUZZ HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, Gori::Store::LinkRefKind::Fuzz, sid)

      view = detail(store)
      view.move_links(1)
      view.selected_resolved_link.not_nil!.link.ref_kind.fuzz?.should be_true
      view.repeater_target_row.not_nil!.live.not_nil!.link.ref_id.should eq(primary)
    end
  end

  # A live REPEATER row is a Repeater tab already — `s` opens it, and `r` will not duplicate a
  # tab into a copy of itself. With nothing else to take, the verb has no target and says so.
  it "has no target on a repeater-only issue" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      issue = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue, Gori::Store::LinkRefKind::Repeater, rid)

      view = detail(store)
      view.related_rows.size.should eq(1)
      view.repeater_target_row.should be_nil
    end
  end

  # A stale flow row has no bytes left to send. An imported issue naming a flow this project
  # never captured is the shape that produces one: a PRUNE nulls `flow_id` as it goes.
  it "skips a stale flow row" do
    with_store do |store|
      store.insert_issue("imported", Gori::Store::Severity::Low, "acme.test", 4242_i64)

      view = detail(store)
      view.related_rows.size.should eq(1)
      view.related_rows[0].live.not_nil!.stale?.should be_true
      view.repeater_target_row.should be_nil
    end
  end

  # And a pruned primary leaves nothing behind at all — the column goes with the link.
  it "loses the primary row when the flow is deleted, column and all" do
    with_store do |store|
      gone = answered_flow(store, "/gone")
      issue = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", gone)
      store.delete_flows([gone]).should be_true
      store.get_issue(issue).not_nil!.flow_id.should be_nil
      detail(store).related_rows.should be_empty
    end
  end

  # The Runner's half: a frozen row goes through the SAME duplicate the Evidence tab's `r`
  # uses (nothing is sent either way), a live flow row through `repeater_flow`.
  it "duplicates a frozen row through the Evidence tab's own builder" do
    body = method_body("evidence", "issue_repeater_flow")
    body.should contain("view.repeater_target_row")
    body.should contain("duplicate_evidence_into_repeater(ev)")
    body.should contain("repeater_flow(res.link.ref_id)")
    # One builder for both surfaces, so the WS-handshake caveat cannot drift into two wordings.
    method_body("evidence", "evidence_duplicate_repeater").should contain("duplicate_evidence_into_repeater(ev)")
    dup = method_body("evidence", "duplicate_evidence_into_repeater")
    dup.should contain("nothing was sent")
  end

  # `o` is gone with the primary flow's meta row: it opened "the linked flow" in History,
  # which is `s` on the first RELATED row.
  it "leaves no issue_open_flow behind" do
    runner_code("issues").should_not contain("def issue_open_flow")
    File.read(File.join(__DIR__, "..", "..", "src", "gori", "verb", "context", "issues.cr"))
      .should_not contain("abstract def issue_open_flow")
  end
end
