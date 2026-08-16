require "../spec_helper"
require "socket"

# The MCP half of round 3's wiring, discover's share of it. Kept in its own file: the
# fuzz/mine/sequence examples in spec/mcp/wiring_spec.cr leave engine fibers behind them, and a
# discover run sharing a process with those took twenty times as long as it does alone.
#
# Helpers are file-local — Crystal's top-level `private def` is file-scoped, so this file
# does not depend on spec/mcp/wiring_spec.cr's or spec/mcp/fuzz_spec.cr's.

private def with_store(&)
  path = File.tempname("gori-mcpwire", ".db")
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

private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_raw(tools, name, args : String) : {String, Bool}
  r = tools.call(name, JSON.parse(args))
  {r.text, r.is_error}
end

private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

private def poll_until_done(tools, status_tool : String, job_id : String, seconds = 20) : JSON::Any
  deadline = Time.instant + seconds.seconds
  loop do
    st = call_json(tools, status_tool, %({"job_id":#{job_id.to_json}}))
    return st unless st["status"].as_s == "running"
    fail "#{status_tool} #{job_id} never left :running within #{seconds}s" if Time.instant > deadline
    sleep 0.02.seconds
  end
end

# A plain HTML origin with no links on the page. Keep-alive capable (several requests per
# connection, no `Connection: close`) on purpose: discover pools its sockets, and an origin
# that hangs up after every response turns each probe into a re-dial plus a retry.
#
# Used even by the examples that only care whether an argument was ACCEPTED. A job started
# against a dead port keeps retrying for the rest of the file, which showed up as unrelated
# later examples taking twenty seconds each.
private def html_origin : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      spawn do
        begin
          conn.read_timeout = 2.seconds
          body = "<html><body>no links here</body></html>"
          while Gori::Proxy::Codec::Http1.read_head(conn)
            conn << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
                    "Content-Length: #{body.bytesize}\r\n\r\n" << body
            conn.flush
          end
        rescue
        end
        conn.close rescue nil
      end
    end
  end
  port
end

# ONE listener for the whole file: each `html_origin` leaks a listening socket plus an
# accept-loop fiber, and a dozen of them made unrelated later examples take twenty seconds.
private HTML_ORIGIN_PORT = html_origin

# ── 5. discover adopts the header refusal ─────────────────────────────────────────────────
#
# `Discover::Headers.parse_lines` drops a CR/LF-carrying value and a non-token name — right,
# since this is an automated crawler splicing the value into every probe's header block — but
# it dropped them SILENTLY. The drop takes `Authorization` with it, so an agent's
# authenticated sweep ran unauthenticated over the whole authenticated surface and reported
# "found nothing", with no error anywhere. `gori run discover` aborts by name; MCP is the
# surface where nobody is watching stderr.
describe "MCP discover_start refuses a header it will not send" do
  it "names the header whose value carries CR/LF instead of crawling without it" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      text, err = call_raw(tools, "discover_start",
        {"url"            => "http://127.0.0.1:#{port}/",
         "headers"        => {"Authorization" => "Bearer t\r\nX-Injected: 1"},
         "allow_unscoped" => true}.to_json)
      err.should be_true
      text.should contain("Authorization")
      text.should_not contain("Bearer t") # never echo the value back — it is the credential
    end
  end

  it "names a header that only becomes unsafe after $VAR expansion" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      saved = Gori::Settings.env_vars
      saved_prefix = Gori::Settings.env_prefix
      begin
        # Built BEFORE the vars are set: constructing Tools runs `Env.load_project(store)`,
        # which would otherwise reset them from the (empty) project.
        tools = tools_for(store)
        Gori::Settings.env_prefix = "$"
        # The header the caller passed is fine; the VALUE bound to TOKEN is not. (A purely
        # TRAILING newline is not this case: both `unsafe_expanded` and `Headers.expand`
        # strip, so it cannot splice anything. An interior CRLF can, and does.)
        Gori::Settings.env_vars = [{"TOKEN", "abc\r\nX-Injected: 1"}]
        text, err = call_raw(tools, "discover_start",
          {"url"            => "http://127.0.0.1:#{port}/",
           "headers"        => {"Authorization" => "Bearer $TOKEN"},
           "allow_unscoped" => true}.to_json)
        err.should be_true
        text.should contain("Authorization")
        text.should contain("$VAR expansion")
      ensure
        Gori::Settings.env_vars = saved || [] of {String, String}
        Gori::Settings.env_prefix = saved_prefix || "$"
      end
    end
  end

  it "still accepts an ordinary header" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      text, err = call_raw(tools, "discover_start",
        {"url" => "http://127.0.0.1:#{port}/",
         "headers" => {"Authorization" => "Bearer plain"},
         "max_requests" => 1, "bruteforce" => false, "allow_unscoped" => true}.to_json)
      fail "discover_start refused an ordinary header: #{text}" if err
      poll_until_done(tools, "discover_status", JSON.parse(text)["job_id"].as_s)
    end
  end
end

# ── 2. discover's incomplete_reason comes from the ENGINE ─────────────────────────────────
#
# Two round-3 fixes met here from opposite sides: one added `queued` + `incomplete_reason` to
# the MCP discover envelopes, the other added `Discover::DoneEvent#budget_exhausted`. MCP was
# left INFERRING the reason from `queued > 0`, and the engine's own predicate is
# `cap_reached? && (frontier non-empty || refused > 0)` — deliberately two clauses, because a
# Calibrate task whose probes were all refused consumes no frontier entry. So a sweep that
# spent its whole budget before a single wordlist candidate was tried drained the frontier to
# EMPTY and came back `status:"done", job_complete:true, has_more:false`, which an agent reads
# as an exhaustive directory sweep and stops looking.
describe "MCP discover reports a budget-capped sweep as incomplete" do
  it "says budget_exhausted even when the frontier drained to EMPTY" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      start = call_json(tools, "discover_start",
        {"url" => "http://127.0.0.1:#{port}/", "max_requests" => 2,
         "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s
      st = poll_until_done(tools, "discover_status", job_id, 45)

      st["sent"].as_i.should be > 0 # not the "nothing reached the wire" terminal error
      # The shape that made the inference wrong: nothing is left QUEUED, and the run is still
      # nowhere near exhaustive — the budget went on calibration, so no wordlist candidate
      # was ever tried.
      st["queued"].as_i.should eq(0)
      st["status"].as_s.should eq("budget_exhausted")
      st["incomplete_reason"].as_s.should eq("budget_exhausted")

      # discover_results carries the same verdict: `has_more` is about the PAGE, so on its own
      # it says "you have seen everything" about a sweep that saw almost nothing.
      res = call_json(tools, "discover_results", %({"job_id":#{job_id.to_json}}))
      res["job_complete"].as_bool.should be_true
      res["has_more"].as_bool.should be_false
      res["incomplete_reason"].as_s.should eq("budget_exhausted")
    end
  end

  it "still reports a spider-only run that finished as a clean done" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      start = call_json(tools, "discover_start",
        {"url" => "http://127.0.0.1:#{port}/", "bruteforce" => false, "keep_alive" => false,
         "concurrency" => 4, "timeout_ms" => 800, "retries" => 0,
         "max_requests" => 200, "allow_unscoped" => true}.to_json)
      st = poll_until_done(tools, "discover_status", start["job_id"].as_s, 45)
      st["status"].as_s.should eq("done")
      st["incomplete_reason"].raw.should be_nil
    end
  end
end

# Round 4 / F6. `fuzz_start` / `mine_start` / `sequence_start` all accept `sni` and all three
# land it on the ClientHello; `discover_start`'s accepted arguments named neither `sni` nor
# `http2`, so an agent had no way to sweep a name-based vhost by IP — the crawler owns its own
# `Host:` header, so there was no second route in.
describe "MCP discover_start — sni / http2 parity" do
  it "advertises both properties in its tool schema" do
    with_store do |store|
      listing = JSON.parse(JSON.build { |j| tools_for(store).list(j) })
      tool = listing.as_a.find! { |t| t["name"].as_s == "discover_start" }
      props = tool["inputSchema"]["properties"].as_h
      props["sni"]["type"].as_s.should eq("string")
      props["http2"]["type"].as_s.should eq("boolean")
    end
  end

  it "accepts them without complaint" do
    with_store do |store|
      tools = tools_for(store)
      # `url` names a closed port on purpose: this asserts ARGUMENT acceptance, not a crawl.
      text, err = call_raw(tools, "discover_start",
        {"url" => "https://127.0.0.1:1/", "sni" => "vhost.local", "http2" => true,
         "bruteforce" => false, "keep_alive" => false, "retries" => 0,
         "max_requests" => 1, "allow_unscoped" => true}.to_json)
      fail "discover_start refused sni/http2: #{text}" if err
      poll_until_done(tools, "discover_status", JSON.parse(text)["job_id"].as_s, 45)
    end
  end
end
