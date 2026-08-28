require "../spec_helper"

# The Probe `exec` custom rule kind (#818): the region goes to a command on stdin and its EXIT
# CODE is the verdict. See `Probe::CustomRule#exec_evidence`.

private def with_store(&)
  path = File.tempname("gori-probe-exec", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def with_hook(body : String, &)
  dir = File.tempname("gori-probe-hook")
  Dir.mkdir_p(dir)
  path = File.join(dir, "hook.sh")
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def exec_flow(store, body : String) : Gori::Store::FlowDetail
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    body: body.to_slice, reason: "OK", content_type: "text/plain", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def exec_rule(command : String,
                      on_failure : Proc(Gori::Probe::CustomRule, String, String, Nil)? = nil) : Gori::Probe::CustomRule
  Gori::Probe::CustomRule.new("1", "external detector", "runs a real detector",
    "response", "body", "exec", command, Gori::Store::Severity::High, "project", true,
    on_failure: on_failure)
end

private def detections(store, r : Gori::Probe::CustomRule, body : String) : Array(Gori::Probe::Detection)
  ctx = Gori::Probe::Passive::Context.new(exec_flow(store, body))
  acc = [] of Gori::Probe::Detection
  r.check(ctx, acc)
  acc
end

describe "Probe exec rule" do
  it "raises a finding on exit 0 and uses stdout as the evidence" do
    with_store do |store|
      with_hook(%q{grep -q SECRET && echo "found it on line 1"}) do |hook|
        dets = detections(store, exec_rule(hook), "a SECRET here")
        dets.size.should eq 1
        dets.first.evidence.should eq "found it on line 1"
        dets.first.severity.should eq Gori::Store::Severity::High
      end
    end
  end

  it "raises nothing on a non-zero exit - that is the detector's own answer" do
    with_store do |store|
      with_hook(%q{grep -q SECRET}) do |hook|
        detections(store, exec_rule(hook), "nothing here").should be_empty
      end
    end
  end

  it "raises a finding with no evidence when the command says nothing" do
    with_store do |store|
      with_hook("exit 0") do |hook|
        dets = detections(store, exec_rule(hook), "anything")
        dets.size.should eq 1
        dets.first.evidence.should be_nil
      end
    end
  end

  it "hands the hook its context in the environment" do
    with_store do |store|
      with_hook(%q{printf '%s %s %s' "$GORI_HOOK" "$GORI_HOST" "$GORI_STATUS"}) do |hook|
        dets = detections(store, exec_rule(hook), "x")
        dets.first.evidence.should eq "probe acme.test 200"
      end
    end
  end

  it "raises NOTHING when the hook cannot run, and reports it rather than reading as clean" do
    # The distinction the report exists for: "the detector looked and found nothing" and "the
    # detector never ran" are the same empty Issues list without it.
    with_store do |store|
      seen = [] of String
      r = exec_rule("/nonexistent/gori-probe-spec",
        on_failure: ->(_r : Gori::Probe::CustomRule, reason : String, _k : String) { seen << reason; nil })
      detections(store, r, "x").should be_empty
      seen.size.should eq 1
      seen.first.should contain "/nonexistent/gori-probe-spec"
    end
  end

  it "raises nothing and reports when the hook times out" do
    with_store do |store|
      prev = Gori::Settings.hook_timeout_secs
      begin
        Gori::Settings.hook_timeout_secs = 1
        seen = [] of String
        r = exec_rule("/bin/sleep 30",
          on_failure: ->(_r : Gori::Probe::CustomRule, reason : String, _k : String) { seen << reason; nil })
        started = Time.instant
        detections(store, r, "x").should be_empty
        (Time.instant - started).should be < 10.seconds
        seen.first.should contain "timed out"
      ensure
        Gori::Settings.hook_timeout_secs = prev
      end
    end
  end

  it "validates the argv at the write surfaces, the way a regex is validated" do
    Gori::Probe::CustomRule.valid_pattern?("./detect --json", "exec").should be_true
    Gori::Probe::CustomRule.valid_pattern?(%q{./detect "oops}, "exec").should be_false
    Gori::Probe::CustomRule.valid_pattern?("", "exec").should be_false
    Gori::Probe::CustomRule::KINDS.should contain "exec"
  end

  it "writes ONE event per broken command however many flows the scan covers" do
    with_store do |store|
      rules = Gori::Probe.custom_rules(store)
      rules.should be_empty
      store.insert_probe_custom_rule("external", "d", "response", "body", "exec",
        "/nonexistent/gori-probe-spec", Gori::Store::Severity::High)
      live = Gori::Probe.custom_rules(store)
      live.size.should eq 1
      3.times { detections(store, live.first, "x").should be_empty }
      store.events_after(0_i64, 200).count { |e| e.kind == "hook_failed" }.should eq 1
    end
  end
end
