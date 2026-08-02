require "./spec_helper"
require "socket"

# The PROVENANCE axis at `Fuzz::Sender` — the ONE send seam every automated sweep dials
# through (Fuzzer, Miner, Sequencer, Repeater minimize, Probe active; TUI, `gori run`, MCP).
#
# `Repeater::Sender` has gated its session-binding pass on `evidence?` since #501.
# `Fuzz::Sender` had no such flag, so every engine that hands it CAPTURED bytes had the
# capture run through `Env.expand_bindings`. Captured traffic is full of `$NAME`-shaped bytes
# nobody typed — the grammar is `$` + `[A-Za-z_]` + `[A-Za-z0-9_]*`, with no delimiter
# requirement, scanned over the BODY too — so Mongo's `$ne`/`$where`, JSON Schema's
# `$ref`/`$schema` and a GraphQL operation (which is MADE of `$variable` references) are all
# tokens here. With an ordinary extract rule named `id` bound, a captured
#
#   {"query":"query GetUser($id: ID!) { user(id: $id) { name } }", ...}
#
# left for the target as `query GetUser(<live session token>: ID!)`.
#
# Reproduced on the wire before the fix, against a recording origin:
#
#   surface                                     requests   carrying the live token
#   MCP minimize_repeater {verbatim: true}          6              12
#   gori run mine <flow> --bind-from <flow>         8               6
#   gori run sequence <flow> --bind-from <flow>     6               5
#   gori run fuzz <flow> --bind-from <flow>         4               3
#   gori run fuzz … --ac (calibration carrier)     10               9
#
# The fix threads the boolean each of those surfaces ALREADY computes (every plan builder
# branches on `PlanOptions#evidence?`; all three minimize surfaces branch on it inside their
# `resolve` proc) down to the seam, where `Sender#send` widens `verbatim` to the maximal
# span. It is deliberately NOT hardcoded per call site: a DRAFT with a bound `$TOKEN` must
# still expand — that is what `--bind-from` exists for — and marking minimize verbatim
# unconditionally would have made it send a literal `$TOKEN`, read a stable 401 baseline,
# judge every candidate "unchanged" and report a bogus minimal request as a success.

private alias F = Gori::Fuzz

private def with_ev_env(&)
  prev_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  yield
ensure
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = prev_prefix || "$"
end

private def with_ev_store(&)
  path = File.tempname("gori-fuzz-evidence", ".db")
  store = Gori::Store.open(path)
  begin
    with_ev_env { yield store }
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def with_ev_layer(layer : Gori::Env::Layer?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = layer
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

# `name` DECLARED and BOUND to `value`, reached the only way a live session reaches it — by
# OBSERVING a response — rather than by poking a hash.
private def ev_bound(store : Gori::Store, name : String, value : String) : Gori::Bindings
  b = Gori::Bindings.load(store)
  b.add(name, "", Gori::ExtractKind::Cookie, "sid").should be_nil
  head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{value}; Path=/\r\nContent-Length: 0\r\n\r\n"
  parsed = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
  b.observe(Gori::Repeater::Result.new(head.to_slice, Bytes.empty, parsed, 1_i64, nil),
    Gori::InterceptFilter::Subject.new(method: "GET", host: "acme.test", target: "/login",
      scheme: "https", status: 200))
  b.values[name]?.should eq(value)
  b
end

# A recording origin. The wire is the only thing that settles a provenance question, so every
# example below asserts on bytes this collected rather than on a stub's argument.
private class EvOrigin
  getter port : Int32
  getter requests = [] of String

  def initialize(@server : TCPServer = TCPServer.new("127.0.0.1", 0))
    @port = @server.local_address.port
  end

  # Serves until closed. No bare `Channel#receive` anywhere (PR #555) — callers poll to a
  # deadline instead.
  def serve : Nil
    spawn do
      while conn = @server.accept?
        begin
          conn.read_timeout = 5.seconds
          head = Gori::Proxy::Codec::Http1.read_head(conn)
          next unless head
          text = String.new(head)
          if m = text.match(/Content-Length:\s*(\d+)/i)
            n = m[1].to_i
            if n > 0
              body = Bytes.new(n)
              conn.read_fully?(body)
              text += String.new(body)
            end
          end
          @requests << text
          body = %({"ok":true,"sid":"x"})
          conn << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                  "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
          conn.flush
        rescue
        ensure
          conn.close rescue nil
        end
      end
    rescue
    end
  end

  def wait_for(n : Int32, timeout : Time::Span = 8.seconds) : Nil
    deadline = Time.instant + timeout
    while @requests.size < n && Time.instant < deadline
      sleep 10.milliseconds
    end
  end

  def close : Nil
    @server.close rescue nil
  end
end

private def ev_outbound : Gori::Outbound
  Gori::Outbound.cli(nil, false)
end

private TOKEN = "SECRETTOKEN123"

# The exact body the round-7 hunter captured: a GraphQL operation carrying `$id`, plus a
# Mongo `$ne` that survives only because no rule happens to be named `ne`.
private GQL = %({"query":"query GetUser($id: ID!) { user(id: $id) { name } }",) +
              %("variables":{"id":"42"},"filter":{"age":{"$ne":null}}})

private def gql_request(port : Int32) : Bytes
  ("POST /graphql?q=hello HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
   "Content-Type: application/json\r\nContent-Length: #{GQL.bytesize}\r\n\r\n#{GQL}").to_slice
end

describe "Gori::Fuzz::Sender#evidence? — captured bytes are not a draft" do
  it "does NOT substitute a bound binding into a CAPTURED body, and the draft path still does" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          req = gql_request(origin.port)
          o = F::Origin.new("http", "127.0.0.1", origin.port)

          evidence = F::Sender.new(o, ev_outbound, false, false, evidence: true)
          evidence.send(req).error.should be_nil
          origin.wait_for(1)

          # EVIDENCE: the client's own bytes, exactly as the origin first saw them.
          wire = origin.requests.first
          wire.should contain("query GetUser($id: ID!) { user(id: $id) { name } }")
          wire.should_not contain(TOKEN)
          wire.should contain(%("$ne":null))

          # DRAFT, same bytes, same seam: expansion is the FEATURE and must still happen,
          # or `--bind-from` would stop refreshing tokens and every sweep would 401.
          draft = F::Sender.new(o, ev_outbound, false, false, evidence: false)
          draft.send(req).error.should be_nil
          origin.wait_for(2)
          origin.requests[1].should contain("query GetUser(#{TOKEN}: ID!)")
        ensure
          origin.close
        end
      end
    end
  end

  it "widens the caller's payload spans rather than competing with them (the MIXED sweep)" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "TOKEN", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          # An operator template with `$TOKEN` in the head AND `$TOKEN` as the payload —
          # round 5/6's case. The two must resolve differently on a DRAFT run.
          tpl = F::Template.parse("GET /q?p=§X§ HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
                                  "Authorization: Bearer $TOKEN\r\n\r\n")
          gen = F::Generator.new(tpl, [F::PayloadSet.new(F::InlineList.new(["$TOKEN"]))],
            F::Config.new(mode: F::Mode::Sniper))
          job = nil.as(F::Job?)
          gen.each { |j| job = j }
          j = job.not_nil!
          o = F::Origin.new("http", "127.0.0.1", origin.port)

          # DRAFT: the template resolves, the payload does not. Unchanged by this fix.
          F::Sender.new(o, ev_outbound, false, false, evidence: false)
            .send(j.bytes, j.payload_spans).error.should be_nil
          origin.wait_for(1)
          origin.requests[0].should contain("/q?p=$TOKEN")
          origin.requests[0].should contain("Bearer #{TOKEN}")

          # EVIDENCE: the maximal span CONTAINS the payload span, so the payload protection
          # round 5/6 won still holds and the surrounding bytes join it. Nothing competes.
          F::Sender.new(o, ev_outbound, false, false, evidence: true)
            .send(j.bytes, j.payload_spans).error.should be_nil
          origin.wait_for(2)
          origin.requests[1].should contain("/q?p=$TOKEN")
          origin.requests[1].should contain("Bearer $TOKEN")
          origin.requests[1].should_not contain(TOKEN)
        ensure
          origin.close
        end
      end
    end
  end

  it "leaves a capture with no `$` byte-identical on both settings" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          body = %({"user":"alice","pass":"pw"})
          req = ("POST /login HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
                 "Content-Length: #{body.bytesize}\r\n\r\n#{body}").to_slice
          o = F::Origin.new("http", "127.0.0.1", origin.port)
          F::Sender.new(o, ev_outbound, false, false, evidence: true).send(req)
          F::Sender.new(o, ev_outbound, false, false, evidence: false).send(req)
          origin.wait_for(2)
          origin.requests[0].should eq(origin.requests[1])
          origin.requests[0].should contain(body)
        ensure
          origin.close
        end
      end
    end
  end

  it "keeps the scope gate and its blocked/blocked_reason accounting exactly as they were" do
    with_ev_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("exclude", "host", "127.0.0.1")
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        s = F::Sender.new(F::Origin.new("http", "127.0.0.1", 9), Gori::Outbound.interactive(scope),
          false, false, evidence: true)
        res = s.send(gql_request(9))
        # `evidence` silences the BINDING half of the gate only. Sandbox / exclude still
        # hard-blocks before the socket, still charges `blocked`, and still names itself.
        res.error.should_not be_nil
        s.blocked.should eq(1_i64)
        s.blocked_reason.should_not be_nil
      end
    end
  end
end

describe "Gori::Fuzz wrapper backends carry the provenance through" do
  it "delegates evidence? rather than defaulting it — the wrapper is what the engine holds" do
    o = F::Origin.new("http", "127.0.0.1", 9)
    inner = F::Sender.new(o, ev_outbound, false, false, evidence: true)
    F::CappedBackend.new(inner, 10_i64).evidence?.should be_true
    F::GatedBackend.new(inner, ev_outbound).evidence?.should be_true
    # …and nested, which is the stack `Repeater::Minimize` and the Miner actually hold.
    F::CappedBackend.new(F::GatedBackend.new(inner, ev_outbound), 10_i64).evidence?.should be_true

    plain = F::Sender.new(o, ev_outbound, false, false)
    plain.evidence?.should be_false
    F::CappedBackend.new(plain, 10_i64).evidence?.should be_false
  end

  it "sends verbatim THROUGH the wrappers, not only on a bare Sender" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          inner = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port),
            ev_outbound, false, false, evidence: true)
          F::CappedBackend.new(inner, 10_i64).send(gql_request(origin.port)).error.should be_nil
          origin.wait_for(1)
          origin.requests.first.should_not contain(TOKEN)
          origin.requests.first.should contain("query GetUser($id: ID!)")
        ensure
          origin.close
        end
      end
    end
  end

  it "gives one spelling to the maximal span, and it disables BOTH halves at the cursor" do
    bytes = "GET /?a=$id HTTP/1.1\r\nHost: h\r\n\r\n$id".to_slice
    spans = F::Backend.all_verbatim(bytes)
    spans.should eq([{0, bytes.size}])
    # `Env.expand`/`scan_unresolved` walk `verbatim` with a cursor: a `{0, n}` span is hit on
    # the first iteration and sets `i = n`, so this is an exact no-op rather than "a scan
    # that matched nothing" — the property the whole fix rests on.
    Gori::Env.unbound(bytes, spans).should be_empty
    Gori::Env.expand_bindings(bytes, spans).should eq(bytes)
  end
end

# ── The site classes. One per engine that reaches the seam by its own road. ──────────────

describe "Gori::Miner::Baseline through an evidence backend" do
  it "calibrates and runs its bogus-name controls on the CAPTURED bytes, unsubstituted" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          base = gql_request(origin.port)
          cfg = Gori::Miner::Config.new
          cfg.stability_rounds = 2
          backend = F::CappedBackend.new(
            F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ev_outbound,
              false, false, evidence: true), 40_i64)
          Gori::Miner::Baseline.new(backend, base, cfg).calibrate([Gori::Miner::Location::Json])
          origin.wait_for(3)
          origin.requests.should_not be_empty
          # Round 6 cleared this site by checking the MATERIAL (gori's canaries cannot hold a
          # `$`) and not the CARRIER. `calibrate` sends the carrier RAW before injecting
          # anything at all, and `control_signals` injects INTO it.
          origin.requests.each { |r| r.should_not contain(TOKEN) }
          origin.requests.first.should contain("query GetUser($id: ID!)")
        ensure
          origin.close
        end
      end
    end
  end
end

describe "Gori::Repeater::Minimize through an evidence backend" do
  it "probes with the stored bytes and still finds the SAME minimal request" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          text = String.new(gql_request(origin.port))
          # The MCP `verbatim: true` resolver, verbatim: no expansion and no CL resync, but
          # the head's CRLF restored — `Minimize.run` normalises it to LF internally.
          resolve = ->(t : String) { Gori::Repeater::Minimize.restore_eol(t, true).to_slice }
          o = F::Origin.new("http", "127.0.0.1", origin.port)

          ev_backend = F::CappedBackend.new(
            F::Sender.new(o, ev_outbound, false, false, evidence: true),
            Gori::Repeater::Minimize::SEND_CAP)
          ev_report = Gori::Repeater::Minimize.run(text, auto_cl: false, resolve: resolve,
            backend: ev_backend) { }
          origin.wait_for(1)
          ev_sent = origin.requests.size
          origin.requests.each { |r| r.should_not contain(TOKEN) }
          origin.requests.first.should contain("query GetUser($id: ID!)")

          # The COMPLEMENT that makes this a threaded flag and not a hardcoded one: the same
          # search over a DRAFT still expands, and — the part that matters — reaches the SAME
          # verdict. If `verbatim` had changed which candidates survive, the fix would have
          # traded a leak for a wrong answer.
          origin.requests.clear
          draft_backend = F::CappedBackend.new(
            F::Sender.new(o, ev_outbound, false, false, evidence: false),
            Gori::Repeater::Minimize::SEND_CAP)
          draft_report = Gori::Repeater::Minimize.run(text, auto_cl: false, resolve: resolve,
            backend: draft_backend) { }
          origin.wait_for(1)

          ev_report.removed.map(&.label).should eq(draft_report.removed.map(&.label))
          ev_report.sends.should eq(draft_report.sends)
          ev_sent.should eq(origin.requests.size)
          origin.requests.any?(&.includes?(TOKEN)).should be_true
        ensure
          origin.close
        end
      end
    end
  end
end

describe "the plan builders thread PlanOptions#evidence? to the seam" do
  it "Miner::Plan gives its Sender the request's provenance, both ways" do
    with_ev_store do |_store|
      cfg = Gori::Miner::Config.new
      cfg.locations = [Gori::Miner::Location::Json]
      req = String.new(gql_request(80))
      captured = Gori::Miner::Plan.build(
        Gori::Miner::PlanOptions.new(req, evidence: true, target: "http://127.0.0.1:19",
          locations: [Gori::Miner::Location::Json], config: cfg), ev_outbound)
      captured.sender.evidence?.should be_true

      cfg2 = Gori::Miner::Config.new
      cfg2.locations = [Gori::Miner::Location::Json]
      drafted = Gori::Miner::Plan.build(
        Gori::Miner::PlanOptions.new(req, evidence: false, target: "http://127.0.0.1:19",
          locations: [Gori::Miner::Location::Json], config: cfg2), ev_outbound)
      drafted.sender.evidence?.should be_false
    end
  end

  it "Sequencer::Plan sends its captured samples verbatim end to end" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          cfg = Gori::Sequencer::Config.new
          cfg.goal = 2
          cfg.concurrency = 1
          cfg.token_loc = Gori::Sequencer::TokenLoc.new(Gori::ExtractKind::JsonPath, "$.sid")
          plan = Gori::Sequencer::Plan.build(
            Gori::Sequencer::PlanOptions.new(gql_request(origin.port), evidence: true,
              target: "http://127.0.0.1:#{origin.port}", config: cfg, verify: false),
            ev_outbound)
          plan.engine.run { |_ev| }
          origin.wait_for(2)
          origin.requests.should_not be_empty
          # Every sample is the same captured request replayed; a substitution here would
          # make the entropy VERDICT a statement about a request nobody captured.
          origin.requests.each { |r| r.should_not contain(TOKEN) }
          origin.requests.first.should contain("query GetUser($id: ID!)")
        ensure
          origin.close
        end
      end
    end
  end

  it "Fuzz::Plan protects the captured template AND the calibration carrier rendered from it" do
    with_ev_store do |store|
      with_ev_layer(ev_bound(store, "id", TOKEN)) do
        origin = EvOrigin.new
        origin.serve
        begin
          cfg = Gori::Fuzz::Config.new(mode: F::Mode::Sniper)
          cfg.auto_calibrate = true
          # `hello` is the only marked position, so the body's `$id` sits in the TEMPLATE —
          # exactly the arrangement `--auto` hides by marking the `$id` span itself.
          plan = Gori::Fuzz::Plan.build(
            Gori::Fuzz::PlanOptions.new(String.new(gql_request(origin.port)), evidence: true,
              target: "http://127.0.0.1:#{origin.port}", marks: ["hello"],
              sources: [Gori::Fuzz::InlineList.new(["A", "B"]).as(Gori::Fuzz::PayloadSource)],
              config: cfg, verify: false),
            ev_outbound)
          plan.engine.calibrate_baseline
          plan.engine.run { |_ev| }
          origin.wait_for(3)
          origin.requests.size.should be >= 3
          # Both send sites: the sweep, and `calibrate_baseline`, whose random nonces are safe
          # but whose CARRIER is this same captured template rendered with them.
          origin.requests.each { |r| r.should_not contain(TOKEN) }
          origin.requests.any?(&.includes?("query GetUser($id: ID!)")).should be_true
        ensure
          origin.close
        end
      end
    end
  end
end
