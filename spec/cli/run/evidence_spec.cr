require "../../spec_helper"

# `gori run evidence` — the headless half of frozen evidence (#1038). The `abort` branches
# call `exit`, so only the success paths and the pure helpers run here; the store contract
# (what a freeze writes, what survives) is spec/store/issue_evidence_spec.cr's.

module Gori::CLI::Run
  def self.resolve_freeze_ends_for_spec(issue_id : Int64?, ref_s : String?,
                                        ref_id : Int64?) : {Int64, Gori::Store::LinkRefKind, Int64}
    resolve_freeze_ends(issue_id, ref_s, ref_id)
  end

  def self.freeze_snapshot_for_spec(store : Gori::Store, kind : Gori::Store::LinkRefKind,
                                    id : Int64, allow_drift : Bool) : Gori::Evidence::Snapshot | String
    freeze_snapshot(store, kind, id, allow_drift)
  end

  def self.evidence_line_for_spec(m : Gori::Store::IssueEvidenceMeta) : String
    evidence_line(m)
  end

  def self.evidence_text_for_spec(ev : Gori::Store::IssueEvidence, include_sensitive : Bool) : String
    evidence_text(ev, include_sensitive)
  end
end

private def frozen(store) : Gori::Store::IssueEvidence
  fid = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "POST", target: "/login", http_version: "HTTP/1.1",
    head: "POST /login HTTP/1.1\r\nHost: acme.test\r\nCookie: sid=abc\r\n\r\n".to_slice, body: "u=a".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, 200, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "welcome\e[2Jhi".to_slice, duration_us: 7_i64))
  iid = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", nil)
  id, status = store.freeze_evidence(iid, Gori::Evidence.from_flow(store.get_flow(fid).not_nil!))
  status.ok?.should be_true
  store.get_evidence(id).not_nil!
end

# The freeze command's own source, comments stripped: `cmd_evidence_freeze` ends in `abort`
# on every refusal and `abort` calls `exit`, so the gate cannot be driven from an example —
# see the header. A comment explaining a rule contains the tokens the rule looks for, which
# is why they go before the whole-file search.
private def freeze_code : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "evidence.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "gori run evidence freeze --allow-drift" do
  it "refuses a Repeater tab edited since its response, with the sentence the other surfaces use" do
    with_store do |store|
      req = "GET /v1 HTTP/1.1\r\nHost: acme.test\r\n\r\n"
      rid = store.insert_repeater("https://acme.test", req.to_slice, false, true, nil, 0)
      store.update_repeater_response(rid, "HTTP/1.1 500 Boom\r\n\r\n".to_slice, "stack".to_slice, nil, 9_i64,
        request_sha256: Gori::Evidence.request_digest(req.to_slice))
      store.update_repeater(rid, "https://acme.test", "GET /v1?debug=1 HTTP/1.1\r\n\r\n".to_slice, false, true, nil)

      # What the command resolves before it writes anything: a sentence, not a snapshot.
      msg = Gori::CLI::Run.freeze_snapshot_for_spec(store, Gori::Store::LinkRefKind::Repeater, rid, false)
        .as(String)
      msg.should contain(Gori::Evidence::DRIFT_REFUSAL)
      msg.should contain("send the tab again, or pass --allow-drift")
      # …and the flag is what lifts it, rather than a second spelling of "yes". The copy that
      # comes back then still carries the drift — gori said what the bytes are, it did not fix them.
      snap = Gori::CLI::Run.freeze_snapshot_for_spec(store, Gori::Store::LinkRefKind::Repeater, rid, true)
        .as(Gori::Evidence::Snapshot)
      snap.request_drifted?.should be_true

      # A tab whose request still matches resolves to its copy either way.
      same = store.insert_repeater("https://acme.test", req.to_slice, false, true, nil, 0)
      store.update_repeater_response(same, "HTTP/1.1 200 OK\r\n\r\n".to_slice, nil, nil, 1_i64,
        request_sha256: Gori::Evidence.request_digest(req.to_slice))
      Gori::CLI::Run.freeze_snapshot_for_spec(store, Gori::Store::LinkRefKind::Repeater, same, false)
        .should be_a(Gori::Evidence::Snapshot)
    end
  end

  it "wires that gate between the snapshot and the write, and names the flag in --help" do
    body = freeze_code
    gate = body[/private def self\.cmd_evidence_freeze.*?\n      end/m].not_nil!
    # Inside the method body, and BEFORE `freeze_evidence`: a refusal that lands after the
    # write is not a refusal. `abort` calls `exit`, so this is the one half of the command
    # an example cannot drive — see the header.
    gate.index("freeze_snapshot(store, kind, rid, allow_drift)").not_nil!
      .should be < gate.index("store.freeze_evidence").not_nil!
    gate.should contain("--allow-drift")
    gate.should contain("allow_drift = true")
  end
end

describe "gori run evidence" do
  it "resolves the freeze triple and admits only the two sources with one exchange" do
    iid, kind, rid = Gori::CLI::Run.resolve_freeze_ends_for_spec(3_i64, "repeater", 9_i64)
    iid.should eq(3_i64)
    kind.should eq(Gori::Store::LinkRefKind::Repeater)
    rid.should eq(9_i64)
    Gori::CLI::Run.resolve_freeze_ends_for_spec(3_i64, "flow", 9_i64)[1].should eq(Gori::Store::LinkRefKind::Flow)
  end

  it "lists one copy per line with its provenance and hash prefixes" do
    with_store do |store|
      ev = frozen(store)
      line = Gori::CLI::Run.evidence_line_for_spec(ev.meta)
      line.should start_with("##{ev.meta.id}  hist ##{ev.meta.source_id}  ")
      line.should contain("POST acme.test/login → 200  #{ev.meta.bytes} bytes  sha256 req #{ev.meta.request_sha256[0, 12]}… res #{ev.meta.response_sha256.not_nil![0, 12]}…")
      # Membership is on the line because the project-wide listing is where an ORPHAN has to
      # be recognisable — the copy no `--issue` listing can reach.
      line.should contain("issues ##{ev.meta.issue_ids.first}")
      store.unlink_evidence(ev.meta.id, ev.meta.issue_ids.first).should be_true
      orphan = store.get_evidence_meta(ev.meta.id).not_nil!
      Gori::CLI::Run.evidence_line_for_spec(orphan).should contain("issues orphaned")
    end
  end

  it "prints the copy with credentials redacted by default, controls stripped, and the raw head on request" do
    with_store do |store|
      ev = frozen(store)
      text = Gori::CLI::Run.evidence_text_for_spec(ev, false)
      text.should contain("frozen evidence ##{ev.meta.id}")
      text.should contain("issues:   ##{ev.meta.issue_ids.first}")
      text.should contain("sha256:   req #{ev.meta.request_sha256}")
      text.should contain("Cookie: [REDACTED]")
      text.should_not contain("sid=abc")
      text.should contain("--- response ---\nHTTP/1.1 200 OK")
      text.should contain("welcome")
      text.should_not contain("\e[2J") # a captured body must not drive the terminal it is printed on
      raw = Gori::CLI::Run.evidence_text_for_spec(ev, true)
      raw.should contain("Cookie: sid=abc")
      raw.should_not contain("--include-sensitive prints them")
    end
  end
end
