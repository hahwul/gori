require "../spec_helper"
require "../support/fake_host"
require "file_utils"
require "../../src/gori/tui/controllers/evidence_controller"

include Gori::Tui

# The Evidence tab's compare hint, while a snapshot is pinned as A.
#
# `evidence_compare` orders the pair by `created_at` — the OLDER copy is always the Comparer's
# left side — and the pin order does not choose that. `A=#7 · move to B · c compare` read as if
# it did: pin the newer copy and the diff comes back mirrored from what the strip promised.
private EVIDENCE_HINT_CA = File.tempname("gori-evidence-hint-ca")
Spec.after_suite { FileUtils.rm_rf(EVIDENCE_HINT_CA) }

private def with_evidence_hint_session(&)
  root = File.tempname("gori-evidence-hint")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("evhint")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(EVIDENCE_HINT_CA), Gori::Verbs.registry, project)
  begin
    yield session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def snapshot(store : Gori::Store, target : String, status : Int32) : Int64
  fid = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    fid, status, "HTTP/1.1 #{status} X\r\n\r\n".to_slice, "b".to_slice, duration_us: 1_i64))
  issue = store.insert_issue("t", Gori::Store::Severity::Low, "acme.test", nil)
  id, st = store.freeze_evidence(issue, Gori::Evidence.from_flow(store.get_flow(fid).not_nil!))
  st.ok?.should be_true
  id
end

describe "the Evidence tab's compare hint" do
  it "says the pair is ordered older→newer, not by which half was pinned" do
    with_evidence_hint_session do |session|
      snapshot(session.store, "/before", 500)
      snapshot(session.store, "/after", 200)
      ctl = EvidenceController.new(FakeHost.new(session))
      ctl.view.reload(session.store)

      ctl.body_hint(:body).should_not contain("A=#")
      anchor = ctl.view.selected_id.not_nil!
      ctl.view.compare_step.should be_nil # the first `c` pins A
      hint = ctl.body_hint(:body)
      hint.should contain("A=##{anchor} · move to B · c compare (older→newer) · esc cancel")
    end
  end
end
