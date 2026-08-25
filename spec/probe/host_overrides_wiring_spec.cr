require "../spec_helper"
require "socket"
require "../../src/gori/authorize/plan"
require "../../src/gori/probe/scan"

# #367 was "every TUI workbench tool forgot `overrides:`". This is its sequel, and the
# interesting part is that #367's fix did not prevent it: THREE more callers of the same
# dialer were written afterwards and each one forgot the same argument again —
#
#   src/gori/authorize/engine.cr    the Authorize tab / CLI / MCP (the operator's report)
#   src/gori/probe/active.cr        every active probe a headless scan sends
#   src/gori/probe/analyzer.cr      every active probe the live TUI sends
#
# — because `Fuzz::Sender#overrides` is a trailing optional argument, so forgetting it
# compiles, sends, and reports findings. Nothing is refused and nothing is logged; the probes
# simply go to whatever DNS resolves while the operator's HOST OVERRIDES pane sits there being
# ignored, and the findings are real findings about the wrong host.
#
# So this file pins the fix at two levels. The `describe` blocks below are BEHAVIOURAL — each
# one dials a real loopback responder through a host that cannot resolve, so the assertion can
# only pass if the override reached the socket, and each is paired with the control run that
# proves it (drop the argument and the send fails). The source-grep guard at the bottom is the
# part that catches the NEXT caller, which is the failure mode all three of these were.

# `execute_active` is the live analyzer's send seam (the twin of the loop in `Active.analyze`).
# Reached in production from a spawned fiber, so a spec drives it directly rather than racing
# `run_active_now` — the same reopen-the-class idiom `passive_feed_source_spec.cr` uses.
module Gori::Probe
  class Analyzer
    def spec_execute_active(rule : Active::Rule, plan : Active::Plan,
                            detail : Store::FlowDetail) : Int32?
      execute_active(rule, plan, detail)
    end
  end
end

private def with_ov_store(&)
  path = File.tempname("gori-ovwire", ".db")
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

# A loopback origin that answers EVERY connection until it is closed, recording the request
# line of each. Authorize deliberately does not keep-alive (one connection per identity) and
# Probe active sends a dozen probes, so a one-shot responder cannot serve either.
private class Responder
  getter hits = [] of String

  def initialize(@body : String = "hello q=hello world")
    @server = TCPServer.new("127.0.0.1", 0)
    @closed = false
    spawn do
      while (conn = @server.accept?)
        handle(conn)
      end
    rescue
      # the server was closed out from under the accept loop — that is the teardown path
    end
  end

  def port : Int32
    @server.local_address.port
  end

  def close : Nil
    return if @closed
    @closed = true
    @server.close rescue nil
  end

  private def handle(conn : TCPSocket) : Nil
    spawn do
      first = conn.gets("\r\n", chomp: true)
      @hits << first.to_s if first
      while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      end
      conn << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{@body.bytesize}\r\n" \
              "Connection: close\r\n\r\n#{@body}"
      conn.flush rescue nil
      conn.close rescue nil
    rescue
      conn.close rescue nil
    end
  end
end

# A captured flow on an UNRESOLVABLE host. That is what makes each assertion below a real
# measurement rather than a coincidence: `nonexistent.invalid` has no address, so the ONLY way
# a request can arrive at the responder is through the override.
private def seed_flow(store : Gori::Store, port : Int32,
                      target : String = "/search?q=hello") : Int64
  head = "GET #{target} HTTP/1.1\r\nHost: nonexistent.invalid:#{port}\r\n" \
         "Cookie: session=ADMIN\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "nonexistent.invalid", port: port,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 19\r\n\r\n".to_slice,
    body: "hello q=hello world".to_slice, duration_us: 1_000_i64))
  store.flush
  id
end

private IDENTS_JSON = <<-JSON
  [{"name": "as-captured", "baseline": true, "set": [], "remove": []},
   {"name": "anonymous", "set": [], "remove": ["Cookie"]}]
  JSON

describe "Authorize honours the project host overrides (the reported defect)" do
  it "replays every identity through the override address" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        ov = Gori::HostOverrides.load(store)
        ov.add("nonexistent.invalid", "127.0.0.1:#{responder.port}").should be_true
        id = seed_flow(store, responder.port, "/admin")
        plan = Gori::Authorize::Plan.build(Gori::Authorize::PlanOptions.new(store,
          flow_ids: [id], identities_json: IDENTS_JSON, verify: false,
          timeout: 3.seconds, overrides: ov), ungated_outbound)
        targets = [] of Gori::Authorize::Target
        plan.run { |_d, t| targets << t }
        targets.size.should eq(1)
        # Both identities REACHED the override. `fully_blocked?`/`uncompared?` is what a run
        # that never got a socket looks like, and that is precisely the before-state.
        targets.first.trials.size.should eq(2)
        targets.first.trials.each do |t|
          t.summary.status.should eq(200)
          t.summary.error.should be_nil
        end
        responder.hits.size.should eq(2)
      end
    ensure
      responder.close
    end
  end

  # The control run. Identical in every respect except the one argument, and it must FAIL —
  # otherwise the assertion above would keep passing after a future edit drops `overrides:`,
  # which is exactly how this defect survived #367.
  it "reaches nothing when the override is not passed (control run)" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        ov = Gori::HostOverrides.load(store)
        ov.add("nonexistent.invalid", "127.0.0.1:#{responder.port}").should be_true
        id = seed_flow(store, responder.port, "/admin")
        plan = Gori::Authorize::Plan.build(Gori::Authorize::PlanOptions.new(store,
          flow_ids: [id], identities_json: IDENTS_JSON, verify: false,
          timeout: 3.seconds), ungated_outbound)
        targets = [] of Gori::Authorize::Target
        plan.run { |_d, t| targets << t }
        # Every identity got a send ERROR (no address for the host), not a reply.
        targets.first.trials.each do |t|
          t.summary.status.should be_nil
          t.summary.error.should_not be_nil
        end
        responder.hits.should be_empty
      end
    ensure
      responder.close
    end
  end
end

describe "Probe::Scan honours the project host overrides (headless CLI + MCP)" do
  it "sends its active probes to the override address" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        Gori::HostOverrides.load(store).add("nonexistent.invalid", "127.0.0.1:#{responder.port}")
          .should be_true
        id = seed_flow(store, responder.port)
        # No `overrides:` argument: `Scan` loads the project's table off its OWN store, which
        # is the seam the CLI and MCP surfaces both come through — so neither has an argument
        # left to forget.
        Gori::Probe::Scan.scan_flows(store, [id], active: true, verify_upstream: false,
          allow_unscoped: true)
        responder.hits.should_not be_empty
        responder.hits.any?(&.includes?("/search")).should be_true
      end
    ensure
      responder.close
    end
  end

  it "reaches nothing when the store holds no override for the host (control run)" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        id = seed_flow(store, responder.port)
        Gori::Probe::Scan.scan_flows(store, [id], active: true, verify_upstream: false,
          allow_unscoped: true)
        responder.hits.should be_empty
      end
    ensure
      responder.close
    end
  end

  # Containment. An override rewrites the TCP connect target and NOTHING else — the scope
  # verdict is taken on `Fuzz::Origin`'s host, which is the name the operator scoped, and the
  # `Host` header, the SNI and the certificate check all keep carrying it (`Upstream
  # .connect_target`). So routing a host to loopback must not turn a refused probe into a sent
  # one. Without this the fix would have a plausible reading in which it WIDENS what gori
  # sends: the whole point of `Outbound` is that "may I send here" is decided once, by name.
  it "does not let an override walk past the scope gate" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "somewhere.else").should be_true
        Gori::HostOverrides.load(store).add("nonexistent.invalid", "127.0.0.1:#{responder.port}")
          .should be_true
        id = seed_flow(store, responder.port)
        # Layer 1 allowlists `somewhere.else` only, and `allow_unscoped` is NOT set.
        Gori::Probe::Scan.scan_flows(store, [id], active: true, verify_upstream: false,
          scope: scope, allow_unscoped: false)
        responder.hits.should be_empty
      end
    ensure
      responder.close
    end
  end
end

describe "Probe::Analyzer honours the project host overrides (live TUI)" do
  it "sends an active probe to the override address held as the session's LIVE instance" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "nonexistent.invalid").should be_true
        ov = Gori::HostOverrides.load(store)
        id = seed_flow(store, responder.port)
        detail = store.get_flow(id).not_nil!
        analyzer = Gori::Probe::Analyzer.new(store, scope,
          Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Active, false,
          overrides: ov)
        # The edit lands AFTER the analyzer was built — the whole reason this holds the live
        # object rather than a snapshot. An analyzer that had loaded its own copy at
        # construction would still be dialing DNS here, which is what an operator who fixes a
        # bad route in the Project tab and re-runs would experience.
        ov.add("nonexistent.invalid", "127.0.0.1:#{responder.port}").should be_true
        rule, plan = first_plan(detail)
        analyzer.spec_execute_active(rule, plan, detail)
        responder.hits.should_not be_empty
      end
    ensure
      responder.close
    end
  end

  it "reaches nothing when the analyzer was given no overrides (control run)" do
    responder = Responder.new
    begin
      with_ov_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "nonexistent.invalid").should be_true
        Gori::HostOverrides.load(store).add("nonexistent.invalid", "127.0.0.1:#{responder.port}")
          .should be_true
        id = seed_flow(store, responder.port)
        detail = store.get_flow(id).not_nil!
        analyzer = Gori::Probe::Analyzer.new(store, scope,
          Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Active, false)
        rule, plan = first_plan(detail)
        analyzer.spec_execute_active(rule, plan, detail)
        responder.hits.should be_empty
      end
    ensure
      responder.close
    end
  end
end

# The first enabled active rule that has something to send against `detail` — which rule it is
# does not matter here (the property under test is the DIAL, not the detection), only that one
# real probe goes out.
private def first_plan(detail : Gori::Store::FlowDetail) : {Gori::Probe::Active::Rule, Gori::Probe::Active::Plan}
  Gori::Probe::Active::RULES.each do |rule|
    next if Gori::Probe.rule_disabled?(rule.info.id, Set(String).new)
    if plan = rule.plan(detail, Gori::Probe::Active::Options::DEFAULT)
      return {rule, plan}
    end
  end
  raise "no active rule produced a plan for this flow — the fixture stopped exercising the seam"
end

# --- the guard that catches the NEXT caller ------------------------------------------------

describe "host overrides reach every dialer (source-grep guard)" do
  # The three defects this file fixes were all ONE missing keyword at a call site that
  # compiled. A behavioural spec pins the three seams that exist today; only a source grep
  # pins the fourth one, which nobody has written yet. Same shape and same reasoning as
  # `spec/outbound_spec.cr`'s "ONE HOME" guard for the Layer-2 refusal strings.
  #
  # Balanced-paren scanning rather than line matching, because every one of these calls wraps:
  # `Fuzz::Sender.new(origin, outbound, http2, verify, timeout: t,` on one line and
  # `overrides: ov)` on the next is the ORDINARY spelling here, and a line-at-a-time grep
  # would report all nine correct call sites as offenders.
  it "names `overrides:` at every call site in src/" do
    seams = {
      # The dialer itself. `overrides` is its trailing OPTIONAL argument — the reason this
      # whole class of defect is possible — and the signature lives in
      # `src/gori/fuzz/engine.cr`, which this rule may not change. So the rule is enforced at
      # the call sites instead.
      "Fuzz::Sender.new",
      "Repeater::Sender.new",
      # …and ONE LEVEL UP, which is where the analyzer's hole actually was. `execute_active`
      # dutifully passes `overrides: @overrides`, so a grep that stopped at the dialer would
      # have found the live TUI compliant while it shipped a permanent nil. A seam that only
      # forwards what it was handed has to be checked where it is HANDED something.
      "Probe::Analyzer.new",
      # Belt and braces. `Engine.live` takes `overrides` as a REQUIRED keyword, so this one is
      # already a compile error rather than a silent nil — it is listed so the rule reads as
      # one rule. Note the blind spot that buys: a call wrapped as `Engine\n  .live(…)` does
      # not match this token, which is a real spelling (two specs use it). That costs nothing
      # HERE precisely because the compiler is the enforcement for this seam; do not add a
      # seam whose only enforcement is this list and then spell its calls that way.
      "Authorize::Engine.live(",
    }
    root = File.expand_path(File.join(__DIR__, "..", ".."))
    offenders = [] of String
    Dir.glob(File.join(root, "src", "**", "*.cr")).sort.each do |path|
      rel = Path[path].relative_to(root).to_s
      lines = File.read_lines(path)
      lines.each_with_index do |line, i|
        next if line.lstrip.starts_with?('#')
        seams.each do |seam|
          next unless line.includes?(seam)
          call = gather_call(lines, i)
          next if call.includes?("overrides:")
          offenders << "#{rel}:#{i + 1}: #{line.strip}"
        end
      end
    end
    fail(<<-MSG) unless offenders.empty?
      every call site of these seams must name `overrides:` — passing nothing is not "no \
      overrides", it is the project's HOST OVERRIDES table silently ignored while the send \
      still goes out and still reports findings (that is #367, and the three callers this \
      spec's behavioural half covers, which each rediscovered it). If nil really is the \
      answer here — no project in play — write `overrides: nil` and say so. Offending lines:
      #{offenders.join("\n")}
      MSG
  end

  # …and the guard has to be able to FAIL. A scanner with a broken paren walk would return an
  # empty offender list forever, which reads exactly like a compliant tree.
  it "flags a call site that omits the argument" do
    src = ["sender = Fuzz::Sender.new(origin, outbound, http2, verify,",
           "  timeout: timeout, keep_alive: true)"]
    gather_call(src, 0).includes?("overrides:").should be_false
    with_ov = ["sender = Fuzz::Sender.new(origin, outbound, http2, verify,",
               "  timeout: timeout, overrides: @overrides)"]
    gather_call(with_ov, 0).includes?("overrides:").should be_true
  end
end

# The full text of the call beginning on `lines[start]`, up to the line on which its parens
# balance (capped, so an unbalanced file cannot run to the end of the source).
private def gather_call(lines : Array(String), start : Int32) : String
  text = ""
  depth = 0
  seen = false
  (start...Math.min(lines.size, start + 12)).each do |i|
    line = lines[i]
    text += line
    line.each_char do |c|
      if c == '('
        depth += 1
        seen = true
      elsif c == ')'
        depth -= 1
      end
    end
    return text if seen && depth <= 0
  end
  text
end
