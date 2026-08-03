require "../spec_helper"
require "socket"

private alias P = Gori::Probe
private alias F = Gori::Fuzz
private alias S = Gori::Store
private alias Codec = Gori::Proxy::Codec

private UNSAFE     = P::Active::Options.new(allow_unsafe: true)
private AGGRESSIVE = P::Active::Options.new(allow_unsafe: true, aggressive: true)

# A captured HTTP/1.1 POST flow whose RESPONSE head carries a front-end fingerprint (so the
# rule's front-end pre-filter passes). Built directly (no store) so the tests assert on the
# rule alone. `resp_head` lets a test drop the front-end hint to exercise the pre-filter.
private def frontended_detail(host : String = "acme.test", port : Int32 = 443, scheme : String = "https",
                              http_version : String = "HTTP/1.1",
                              resp_head : String = "HTTP/1.1 200 OK\r\nVia: 1.1 varnish\r\nContent-Type: text/html\r\n\r\n") : S::FlowDetail
  target = "/app"
  head = "POST #{target} HTTP/1.1\r\nHost: #{host}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
  row = S::FlowRow.new(
    1_i64, 1_i64, scheme, "POST", host, port, target,
    200, 100_i64, S::FlowState::Complete, 11_i64, 1_i64, "text/html")
  S::FlowDetail.new(row, http_version, head.to_slice, "{}".to_slice,
    resp_head.to_slice, "<html></html>".to_slice)
end

# request_framing over the HEAD of a crafted request (mirrors the rule's own off-wire guard).
private def framing_raises?(req : Bytes) : Bool
  s = String.new(req)
  i = s.index("\r\n\r\n")
  head = i ? req[0, i + 4] : req
  Codec::Body.request_framing(Codec::Http1.parse_request_head(head))
  false
rescue Gori::Error
  true
rescue
  false
end

private def obfuscated?(req : Bytes) : Bool
  s = String.new(req)
  i = s.index("\r\n\r\n")
  head = i ? req[0, i + 4] : req
  Codec::Http1.obfuscated_header?(head)
end

# ── synthetic Repeater::Result builders for the pure verdict layer ──────────────────────
private def r_fast(us : Int64 = 50_000_i64) : Gori::Repeater::Result
  Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, us)
end

private def r_hung(us : Int64 = 8_000_000_i64) : Gori::Repeater::Result
  # A read that timed out on a blocked tier: errored, and far slower than the baseline.
  Gori::Repeater::Result.new(Bytes.new(0), nil, nil, us, "read timed out")
end

private def r_timed_out(us : Int64 = 8_000_000_i64) : Gori::Repeater::Result
  Gori::Repeater::Result.new(Bytes.new(0), nil, nil, us, nil, false, timed_out: true)
end

private def r_ok_complete(body : String = "ok") : Gori::Repeater::Result
  head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n"
  Gori::Repeater::Result.new(head.to_slice, body.to_slice, nil, 100_000_i64)
end

private def r_incomplete : Gori::Repeater::Result
  Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n".to_slice, nil, nil, 100_000_i64, nil, true)
end

private def r_error(msg : String = "boom") : Gori::Repeater::Result
  Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 100_000_i64, msg)
end

private def r_reflects_canary : Gori::Repeater::Result
  body = "you asked for gori-smuggle-deadbeef"
  head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n"
  Gori::Repeater::Result.new(head.to_slice, body.to_slice, nil, 100_000_i64)
end

# A full timing-layer result list: two fast baselines followed by the three variants' probe
# pairs (each `pair` is a {a, b} tuple), then an optional differential {smuggle, benign}.
private def results_for(clte : {Gori::Repeater::Result, Gori::Repeater::Result},
                        tecl : {Gori::Repeater::Result, Gori::Repeater::Result},
                        tete : {Gori::Repeater::Result, Gori::Repeater::Result},
                        baseline : Gori::Repeater::Result = r_fast,
                        baseline2 : Gori::Repeater::Result = r_fast,
                        diff : {Gori::Repeater::Result, Gori::Repeater::Result}? = nil) : Array(Gori::Repeater::Result)
  out = [baseline, baseline2, clte[0], clte[1], tecl[0], tecl[1], tete[0], tete[1]]
  if d = diff
    out << d[0] << d[1]
  end
  out
end

# A recording backend: captures the wire bytes of every `send` (the injected-backend path in
# Active.analyze routes pipeline members through the DEFAULT send_pipeline → per-member `send`).
private class RecordingBackend < F::Backend
  getter origin : F::Origin
  getter wire = [] of String

  def initialize(@origin : F::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    send(bytes, nil)
  end

  def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Gori::Repeater::Result
    @wire << String.new(bytes)
    body = "{}"
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.to_slice, nil, 40_000_i64)
  end
end

private def with_store(&)
  path = File.tempname("gori-smuggle", ".db")
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

describe Gori::Probe::Active::RequestSmuggling do
  rule = P::Active::RequestSmuggling.new

  # ─────────────────────────────────────────────────────────────────────────────
  # LAYER 1 — Craft (pure): the crafted bytes trip gori's own codec exactly as the
  # technique requires, with the exact chunk shapes the timing signal depends on.
  # ─────────────────────────────────────────────────────────────────────────────
  describe "craft" do
    it "builds a benign, cleanly-framed baseline and 3×2 timing probes" do
      plan = rule.plan(frontended_detail, UNSAFE).not_nil!
      # baseline (plan.request) is a benign CL:0 POST — framing is NOT ambiguous.
      framing_raises?(plan.request).should be_false
      String.new(plan.request).should contain("Content-Length: 0")
      # followups = [baseline2, clte, clte, tecl, tecl, tete, tete]
      plan.followups.size.should eq(7)
    end

    it "makes the CL.TE probe raise the CL+TE rejection with a lone incomplete chunk" do
      plan = rule.plan(frontended_detail, UNSAFE).not_nil!
      clte = plan.followups[1]
      s = String.new(clte)
      s.should contain("Content-Length: 6")
      s.should contain("Transfer-Encoding: chunked")
      s.should contain("1\r\nZ\r\n") # one 1-byte chunk, NO terminating 0-chunk
      framing_raises?(clte).should be_true
    end

    it "makes the TE.CL probe raise the CL+TE rejection with a short CL and a bare terminator" do
      plan = rule.plan(frontended_detail, UNSAFE).not_nil!
      tecl = plan.followups[3]
      s = String.new(tecl)
      s.should contain("Content-Length: 6") # one greater than the 5 body bytes sent
      s.should contain("0\r\n\r\n")          # terminating chunk only
      framing_raises?(tecl).should be_true
    end

    it "makes the TE.TE probe obfuscated AND framing-rejected (space before the colon)" do
      plan = rule.plan(frontended_detail, UNSAFE).not_nil!
      tete = plan.followups[5]
      String.new(tete).should contain("Transfer-Encoding : chunked")
      obfuscated?(tete).should be_true
      framing_raises?(tete).should be_true
    end

    it "arms the differential pipeline (self-attributed canary) ONLY under aggressive+unsafe" do
      # Plain unsafe: timing only, no pipeline, no probe_timeout.
      plan = rule.plan(frontended_detail, UNSAFE).not_nil!
      plan.pipeline.should be_empty
      plan.probe_timeout.should be_nil

      # Aggressive+unsafe: a [complete-smuggle+canary, benign GET /] pipeline group.
      aplan = rule.plan(frontended_detail, AGGRESSIVE).not_nil!
      aplan.pipeline.size.should eq(2)
      String.new(aplan.pipeline[0]).should contain("gori-smuggle-") # self-attributed canary path
      String.new(aplan.pipeline[0]).should contain("Transfer-Encoding: chunked")
      String.new(aplan.pipeline[1]).should start_with("GET / HTTP/1.1")
      aplan.probe_timeout.should_not be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Pre-filter + dedup equivalence
  # ─────────────────────────────────────────────────────────────────────────────
  describe "pre-filter" do
    it "declines without allow_unsafe (synthetic POST bodies)" do
      rule.plan(frontended_detail, P::Active::Options::DEFAULT).should be_nil
      rule.dedup_key(frontended_detail, P::Active::Options::DEFAULT).should be_nil
    end

    it "declines on HTTP/2 (no CL/TE ambiguity there)" do
      rule.plan(frontended_detail(http_version: "HTTP/2"), UNSAFE).should be_nil
    end

    it "declines when no front-end fingerprint is present in the response head" do
      plain = frontended_detail(resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n")
      rule.plan(plain, UNSAFE).should be_nil
    end

    it "fires the pre-filter on a Server: cloudflare hint too" do
      cf = frontended_detail(resp_head: "HTTP/1.1 200 OK\r\nServer: cloudflare\r\n\r\n")
      rule.plan(cf, UNSAFE).should_not be_nil
    end

    it "keeps dedup_key byte-identical to plan's, and tags |aggr when the differential is armed" do
      rule.dedup_key(frontended_detail, UNSAFE).should eq(rule.plan(frontended_detail, UNSAFE).not_nil!.dedup_key)
      rule.dedup_key(frontended_detail, AGGRESSIVE).should eq(rule.plan(frontended_detail, AGGRESSIVE).not_nil!.dedup_key)
      rule.dedup_key(frontended_detail, UNSAFE).not_nil!.should_not contain("aggr")
      rule.dedup_key(frontended_detail, AGGRESSIVE).not_nil!.should contain("aggr")
    end

    it "dedup_key is nil in EXACTLY the cases plan is (equivalence invariant, incl. gated-out)" do
      cases = [
        {frontended_detail, UNSAFE},                                                # eligible
        {frontended_detail, AGGRESSIVE},                                            # eligible + armed
        {frontended_detail, P::Active::Options::DEFAULT},                           # no allow_unsafe
        {frontended_detail(http_version: "HTTP/2"), UNSAFE},                        # h2
        {frontended_detail(resp_head: "HTTP/1.1 200 OK\r\n\r\n"), UNSAFE},          # no front-end hint
      ]
      cases.each do |(d, o)|
        rule.dedup_key(d, o).should eq(rule.plan(d, o).try(&.dedup_key))
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LAYER 3 — Verdict (pure, synthetic Results).
  # ─────────────────────────────────────────────────────────────────────────────
  describe "verdict" do
    detail = frontended_detail
    plan = rule.plan(detail, AGGRESSIVE).not_nil!

    it "fires High for a variant whose BOTH timing probes hung against a fast baseline" do
      res = results_for(clte: {r_hung, r_hung}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast})
      dets = rule.detections_all(plan, res, detail)
      dets.size.should eq(1)
      dets[0].code.should eq("request_smuggling_clte")
      dets[0].severity.should eq(S::Severity::High)
      dets[0].evidence.not_nil!.should contain("2/2")
    end

    it "also fires on a timed_out (not just errored) probe pair" do
      res = results_for(clte: {r_fast, r_fast}, tecl: {r_timed_out, r_timed_out}, tete: {r_fast, r_fast})
      dets = rule.detections_all(plan, res, detail)
      dets.map(&.code).should eq(["request_smuggling_tecl"])
    end

    it "fires nothing when no probe hung (fast+fast everywhere)" do
      res = results_for(clte: {r_fast, r_fast}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast})
      rule.detections_all(plan, res, detail).should be_empty
    end

    it "DECLINES a variant on jitter (only one of its two probes hung)" do
      res = results_for(clte: {r_hung, r_fast}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast})
      rule.detections_all(plan, res, detail).should be_empty
    end

    it "DECLINES the whole flow on a slow/unstable baseline (a hang is not attributable)" do
      slow = r_fast(2_000_000_i64) # 2s > BASE_FAST
      res = results_for(clte: {r_hung, r_hung}, tecl: {r_hung, r_hung}, tete: {r_hung, r_hung},
        baseline: slow, baseline2: slow)
      rule.detections_all(plan, res, detail).should be_empty
    end

    it "DECLINES when a baseline failed to send (no anchor for the timing test)" do
      res = results_for(clte: {r_hung, r_hung}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast},
        baseline2: r_error)
      rule.detections_all(plan, res, detail).should be_empty
    end

    it "escalates to Critical when the differential confirm fires (benign follow-up incomplete)" do
      res = results_for(clte: {r_hung, r_hung}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast},
        diff: {r_ok_complete, r_incomplete})
      dets = rule.detections_all(plan, res, detail)
      dets.size.should eq(1)
      dets[0].severity.should eq(S::Severity::Critical)
      dets[0].evidence.not_nil!.should contain("differential confirmed")
    end

    it "confirms via a benign follow-up that REFLECTS the smuggled canary" do
      res = results_for(clte: {r_hung, r_hung}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast},
        diff: {r_ok_complete, r_reflects_canary})
      dets = rule.detections_all(plan, res, detail)
      dets[0].severity.should eq(S::Severity::Critical)
    end

    it "does NOT count a differential confirm when the smuggle itself errored (follow-up was skipped)" do
      # smuggle errored ⇒ send_pipeline retired the socket ⇒ benign is a 'skipped' Result whose
      # error says nothing about a poison. Timing still fires (High), but never escalates.
      res = results_for(clte: {r_hung, r_hung}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast},
        diff: {r_error, r_error("skipped — the connection closed earlier in the group")})
      dets = rule.detections_all(plan, res, detail)
      dets.size.should eq(1)
      dets[0].severity.should eq(S::Severity::High)
    end

    it "emits a clte finding when the differential confirms but no timing variant pinned" do
      res = results_for(clte: {r_fast, r_fast}, tecl: {r_fast, r_fast}, tete: {r_fast, r_fast},
        diff: {r_ok_complete, r_reflects_canary})
      dets = rule.detections_all(plan, res, detail)
      dets.size.should eq(1)
      dets[0].code.should eq("request_smuggling_clte")
      dets[0].severity.should eq(S::Severity::Critical)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # LAYER 2 — Seam: the pipeline lands on ONE socket in order; group refusal;
  # both send loops route the pipeline.
  # ─────────────────────────────────────────────────────────────────────────────
  describe "seam" do
    it "Sender#send_pipeline sends the whole group on ONE socket, in order" do
      # A keep-alive origin tagging every response with its connection id; identical ids prove
      # one shared socket (mirrors spec/repeater_spec.cr's send_pipeline harness).
      origin = TCPServer.new("127.0.0.1", 0)
      port = origin.local_address.port
      spawn do
        cid = 0
        while conn = origin.accept?
          cid += 1
          id = cid
          begin
            while head = Codec::Http1.read_head(conn)
              path = String.new(head).split(' ')[1]? || "?"
              body = "c#{id}#{path}"
              conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
              conn.flush
            end
          rescue
          ensure
            conn.close rescue nil
          end
        end
      end

      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", port), ungated_outbound, false, false)
      reqs = ["GET /a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
              "GET /b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice]
      results = sender.send_pipeline(reqs)
      results.size.should eq(2)
      results.all?(&.ok?).should be_true
      String.new(results[0].body.not_nil!).should eq("c1/a")
      String.new(results[1].body.not_nil!).should eq("c1/b") # SAME c1 → one connection, in order
    ensure
      origin.try &.close
    end

    it "Sender#send_pipeline refuses the WHOLE group when any member is out of scope" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("exclude", "host", "blocked.test")
        sender = F::Sender.new(F::Origin.new("https", "blocked.test", 443),
          Gori::Outbound.interactive(scope), false, false)
        reqs = ["GET /a HTTP/1.1\r\nHost: blocked.test\r\n\r\n".to_slice,
                "GET /b HTTP/1.1\r\nHost: blocked.test\r\n\r\n".to_slice]
        results = sender.send_pipeline(reqs)
        results.size.should eq(2)
        results.all? { |r| !r.ok? }.should be_true # every member refused (group refusal)
        sender.blocked.should be > 0_i64
      end
    end

    it "the Backend DEFAULT send_pipeline delegates to per-member send" do
      backend = RecordingBackend.new(F::Origin.new("http", "127.0.0.1", 80))
      reqs = ["GET /x HTTP/1.1\r\n\r\n".to_slice, "GET /y HTTP/1.1\r\n\r\n".to_slice]
      backend.send_pipeline(reqs).size.should eq(2)
      backend.wire.size.should eq(2) # one `send` per member
    end

    it "Active.analyze routes the pipeline to the wire when the rule is ENABLED (default-off flip)" do
      backend = RecordingBackend.new(F::Origin.new("https", "acme.test", 443))
      # request_smuggling is default-OFF, so its id PRESENT in the disabled set means ENABLED.
      P::Active.analyze(frontended_detail, outbound: ungated_outbound, backend: backend,
        opts: AGGRESSIVE, disabled: Set{"request_smuggling"})
      # The differential smuggle (canary) and a CL.TE timing probe both reached the wire.
      backend.wire.any?(&.includes?("gori-smuggle-")).should be_true
      backend.wire.any?(&.includes?("Transfer-Encoding: chunked")).should be_true
    end

    it "Active.analyze sends NO smuggling probe when the rule is default-off (empty disabled set)" do
      backend = RecordingBackend.new(F::Origin.new("https", "acme.test", 443))
      P::Active.analyze(frontended_detail, outbound: ungated_outbound, backend: backend,
        opts: AGGRESSIVE) # disabled defaults to empty ⇒ default-off rule stays off
      backend.wire.none?(&.includes?("gori-smuggle-")).should be_true
    end

    it "the Analyzer loop (the TUI twin) runs the rule and its timing probes reach a real socket" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      seen = [] of String
      spawn do
        while sock = server.accept?
          begin
            head = Codec::Http1.read_head(sock)
            seen << (head ? String.new(head) : "")
            sock << "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sock.flush
          rescue
          ensure
            sock.close rescue nil
          end
        end
      end

      begin
        with_store do |store|
          scope = Gori::Scope.load(store)
          scope.add("include", "host", "127.0.0.1")
          # Enable the default-off rule for this project (presence ⇒ enabled).
          store.set_probe_disabled_rules(Set{"request_smuggling"})
          detail = frontended_detail(host: "127.0.0.1", port: port, scheme: "http")
          a = P::Analyzer.new(store, scope, Channel(S::FlowEvent).new(1), P::Mode::Active, false)
          a.start
          a.run_active_now(detail, allow_unsafe: true)
          # request_smuggling runs LAST in the RULES list, so wait for its marker specifically
          # (not a bare count) — poll to a deadline without a bare receive (PR #555 idiom).
          deadline = Time.instant + 12.seconds
          until seen.any?(&.includes?("Transfer-Encoding: chunked")) || Time.instant > deadline
            sleep 20.milliseconds
          end
          a.stop
        end
        seen.should_not be_empty
        # A CL.TE / TE.CL timing probe (Transfer-Encoding: chunked) reached the socket through
        # the analyzer's own send loop — proving execute_active runs request_smuggling end-to-end.
        seen.any?(&.includes?("Transfer-Encoding: chunked")).should be_true
      ensure
        server.close
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # C3 — default-off wiring (the flip lives in Probe.rule_disabled?/set_rule_enabled).
  # ─────────────────────────────────────────────────────────────────────────────
  describe "default-off wiring" do
    it "treats request_smuggling as DISABLED on a fresh project (empty set)" do
      empty = Set(String).new
      P.rule_disabled?("request_smuggling", empty).should be_true
      P.rule_enabled?("request_smuggling", empty).should be_false
      # An ordinary rule is unaffected — enabled on a fresh project.
      P.rule_enabled?("reflected_param", empty).should be_true
    end

    it "enabling a default-off rule stores its id PRESENT; disabling removes it" do
      s = Set(String).new
      P.set_rule_enabled(s, "request_smuggling", true)
      s.includes?("request_smuggling").should be_true
      P.rule_enabled?("request_smuggling", s).should be_true
      P.set_rule_enabled(s, "request_smuggling", false)
      s.includes?("request_smuggling").should be_false
      P.rule_enabled?("request_smuggling", s).should be_false
    end

    it "an ordinary rule keeps the historic sense (present ⇒ disabled)" do
      s = Set(String).new
      P.set_rule_enabled(s, "reflected_param", false)
      s.includes?("reflected_param").should be_true
      P.rule_enabled?("reflected_param", s).should be_false
    end

    it "the Rules catalog shows request_smuggling disabled by default" do
      with_store do |store|
        entry = P::RuleCatalog.load(store).find { |e| e.id == "request_smuggling" }.not_nil!
        entry.enabled.should be_false
        entry.kind.should eq("active")
      end
    end
  end
end
