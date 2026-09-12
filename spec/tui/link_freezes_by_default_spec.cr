require "../spec_helper"

include Gori::Tui

# "Link…" freezes the exchange it links (#1038). There used to be a second verb on `Z`, which
# made the operator answer "pointer or bytes?" at the moment of FILING — a question about the
# storage model, asked while their attention is on the finding, and whose answer was almost
# always "bytes". One verb now: ↵ on an ISSUE row links AND freezes whenever the ref has an
# exchange, and the LINK is the primary act — a refusal, a declined gate or the quota changes
# what is KEPT, never whether the link happened.
#
# `Runner.new` owns a terminal and appears nowhere under spec/ (see the note in
# `evidence_drift_confirm_spec.cr`), so the sentence the operator reads is driven through the
# class-level seam `Runner::LinkOutcome`, the writes are driven through the Store, and the
# chaining between them is pinned by reading the source with comments stripped.
private def runner_code(file : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", file))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

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
    fid, 200, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "body".to_slice, duration_us: 9_i64))
  fid
end

describe "the one toast a link reports" do
  it "names the owner and the copy that rode along" do
    out = Runner::LinkOutcome.new("issue #3", 1, 1, 0, [7_i64], 12_000_i64, nil)
    out.toast.should eq("linked to issue #3 · frozen as evidence #7 (12KB)")
  end

  it "says nothing about freezing when the destination cannot own evidence" do
    # A note owns no evidence, so its ↵ never goes through this path at all — but the same
    # shape covers a fuzz/miner ref on an issue, which has no single exchange to copy.
    Runner::LinkOutcome.new("note Auth flow", 1, 1, 0, [] of Int64, 0_i64, nil)
      .toast.should eq("linked to note Auth flow")
  end

  it "NAMES what it could not freeze, because a bare \"linked\" reads as \"kept\"" do
    never_sent = "repeater #2 has never been sent — send it first, then freeze the exchange"
    Runner::LinkOutcome.new("issue #3", 1, 1, 0, [] of Int64, 0_i64, never_sent)
      .toast.should eq("linked to issue #3 · not frozen: #{never_sent}")

    # The quota case is the one that used to refuse the whole batch, LINK INCLUDED. The link
    # is the act now, so it lands and the refusal rides the same sentence.
    quota = "evidence quota reached (256MB of 256MB) — delete a frozen copy first"
    out = Runner::LinkOutcome.new("issue #3", 1, 1, 0, [] of Int64, 0_i64, quota)
    out.toast.should start_with("linked to issue #3 · not frozen: evidence quota reached")
  end

  it "accounts for every ref of a batch — linked, already linked, gone, frozen" do
    batch = Runner::LinkOutcome.new("issue #3", 5, 3, 1, [11_i64, 12_i64], 2_000_i64, nil)
    batch.toast.should eq("linked 3 flows to issue #3 · 1 already linked · 1 no longer available · 2 frozen (2.0KB)")

    # A partial freeze plus its reason, so "2 frozen" can never stand for five.
    Runner::LinkOutcome.new("issue #3", 5, 5, 0, [11_i64, 12_i64], 2_000_i64, "store busy")
      .toast.should end_with("· 2 frozen (2.0KB) · not frozen: store busy")
  end

  it "does not claim a link it did not write" do
    Runner::LinkOutcome.new("issue #3", 1, 0, 0, [] of Int64, 0_i64, nil)
      .toast.should eq("already linked to issue #3")
  end
end

describe "↵ on an issue row" do
  it "writes the link AND the frozen copy in one go" do
    with_store do |store|
      fid = answered_flow(store, "/login")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      snap = Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Flow, fid)
      snap.should be_a(Gori::Evidence::Snapshot)

      eid, status = store.freeze_evidence(issue, snap.as(Gori::Evidence::Snapshot), link: true)
      status.ok?.should be_true
      # Both halves, from ONE call: the pointer the operator asked for and the bytes that
      # outlive it.
      store.get_evidence(eid).should_not be_nil
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue)
      links.map(&.ref_id).should eq([fid])
      links.map(&.ref_kind).should eq([Gori::Store::LinkRefKind::Flow])
    end
  end

  it "still links when the quota refuses the bytes" do
    with_store do |store|
      fid = answered_flow(store, "/login")
      issue = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", nil)
      snap = Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Flow, fid).as(Gori::Evidence::Snapshot)

      _, status = store.freeze_evidence(issue, snap, link: true, quota: 1_i64)
      status.quota?.should be_true
      # `freeze_evidence` wrote nothing at all on the refusal — which is exactly why the
      # Runner must file the plain link itself rather than treating the freeze as the write.
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue).should be_empty
      store.add_links(Gori::Store::LinkOwnerKind::Issue, issue,
        [{Gori::Store::LinkRefKind::Flow, fid}]).should eq(1)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue).map(&.ref_id).should eq([fid])
    end
  end

  it "has a refusal SENTENCE for every ref it cannot freeze" do
    with_store do |store|
      # Pending: the response is still in flight and will land on this same row.
      pending = store.insert_flow(captured("/slow"))
      Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Flow, pending)
        .should eq("flow ##{pending} has no response yet — wait for it to complete, then freeze the exchange")
      # A fuzz/miner session is a template plus a run, not one exchange.
      Gori::Evidence.snapshot_for(store, Gori::Store::LinkRefKind::Fuzz, 1_i64)
        .as(String).should contain("no single exchange")
    end
  end

  it "stays silent about a ref that was never a candidate for freezing" do
    # The sentence above is the right answer to `evidence freeze --ref=fuzz`; it is noise on
    # a Fuzzer/Miner "Link…", where the operator asked for a pointer and a pointer is all the
    # kind can give. `Evidence.freezable?` is the gate, checked before the store is touched.
    snaps = runner_code("runner/evidence.cr")[/private def evidence_snapshots.*?\n  end/m].not_nil!
    snaps.should contain("next LinkSnapshot.new(kind, id, nil, nil) unless Evidence.freezable?(kind)")
    Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Fuzz).should be_false
    Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Miner).should be_false
    Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Flow).should be_true
    Gori::Evidence.freezable?(Gori::Store::LinkRefKind::Repeater).should be_true
  end
end

describe "the one-verb link path" do
  code = runner_code("runner/links.cr")
  evidence = runner_code("runner/evidence.cr")

  it "sends an ISSUE row through the freeze path and a NOTE row through the plain link" do
    picked = code[/private def link_picked.*?\n  end/m].not_nil!
    picked.should contain("link_and_freeze(issue_id, owner, snaps, back)")
    # A note owns no evidence, so its arm must stay the pointer-only commit — and it must not
    # ride `on_close`, which exists only because a freeze can raise a confirm.
    note_arm = picked[/in \.note\?.*?end/m].not_nil!
    note_arm.should contain("commit_links_to_owner")
    note_arm.should_not contain("freeze")
    # The mode is gone with the verb: no `freeze?` branch is left to fall into.
    picked.should_not contain("lp.freeze?")
    code.should_not contain("issues_only")
  end

  it "keeps every ref the picker was opened with, freezable or not" do
    snaps = evidence[/private def evidence_snapshots.*?\n  end/m].not_nil!
    # `refs.map`, not a select-and-append: a ref with no exchange comes back CARRYING its
    # refusal, so the commit can still link it and the toast can still name it. Dropping it
    # here is what made the old picker refuse a legitimate pointer to the tab in front of you.
    snaps.should contain("refs.map do |kind, id|")
    snaps.should contain("LinkSnapshot.new(kind, id, nil, res)")
    snaps.should contain("batch_within_cap") # the 20-copy ceiling survives the rewrite
  end

  it "links whatever the freeze did not write, so a refusal is never a silent partial" do
    finish = evidence[/private def finish_link.*?\n  end/m].not_nil!
    # `write_frozen` stops at the first refusal, so everything past `frozen.size` — and every
    # ref that was never freezable — still needs its row.
    finish.should contain("kept <= frozen.size")
    finish.should contain("add_links(Store::LinkOwnerKind::Issue, issue_id, live.map(&.ref))")
    finish.should contain("LinkOutcome.new")

    # A declined gate takes the same path: the operator said "don't keep the bytes", not
    # "don't file the link".
    attach = evidence[/private def link_and_freeze.*?\n  end/m].not_nil!
    attach.should contain("declined = -> { finish_link(issue_id, owner, snaps, none, FREEZE_DECLINED) }")
    attach.should contain("declined: declined")
  end
end

describe "History's Add issue" do
  it "hands the form the copies, gated before it opens" do
    body = runner_code("runner/issues.cr")
    create = body[/def issue_create.*?\n  end/m].not_nil!
    # The primary flow AND every extra mark — the same set that is attached — and the gates
    # are answered first, because the operator is about to spend a minute on a title and the
    # form's own commit already chains the open-vs-stay confirm.
    create.should contain("refs = ([row.id] + extra).map { |id| {Store::LinkRefKind::Flow, id} }")
    create.should contain("with_freeze_gates(evidence_snapshots(refs).compact_map(&.snapshot)")
    create.should contain("snapshots: copies")
  end

  it "writes those copies on every create branch, not only the picker's" do
    # `form.snapshots` used to be written inside the `if ref = form.link_ref` arm, which is the
    # link picker's create row alone — Add issue carries no `link_ref`, so its copies would
    # have been taken and then dropped on the floor.
    shell = runner_code("runner.cr")
    form = shell[/private def create_issue_from_form.*?\n      true\n    end/m].not_nil!
    form.scan(/write_form_snapshots\(new_id, form\)/).size.should eq(3)

    write = runner_code("runner/evidence.cr")[/private def write_form_snapshots.*?\n  end/m].not_nil!
    write.should contain("write_frozen(issue_id, form.snapshots, false)") # linked by the insert
    write.should contain("not frozen: #{"#"}{refusal}")
  end
end
