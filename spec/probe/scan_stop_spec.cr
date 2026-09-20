require "../spec_helper"
require "socket"
require "../../src/gori/probe/scan"

# `Probe::Scan`'s cooperative stop (#1103).
#
# The defect it closes is not "a flag was ignored" — there was no flag. A headless active scan
# ran to completion whatever the caller did, so an MCP `probe_scan{active:true}` the client had
# cancelled went on putting real attack probes on a third party's server for up to
# `PROBE_ACTIVE_MAX_FLOWS` flows. The resource gori was failing to free was someone else's.
#
# So every example here COUNTS REQUESTS AT AN ORIGIN. A spec that asserted the predicate was
# consulted would pass against a scan that consulted it and sent anyway, which is exactly the
# shape of the bug.

# A loopback origin that answers every connection and counts the request LINES it was handed.
# `hits` is read from the spec fiber and from a `stop` predicate while the scan is in flight,
# which is safe for the reason the rest of this tree relies on: gori never builds with
# `-Dpreview_mt`, so the counter is only ever advanced at a yield point.
private class CountingOrigin
  getter hits = 0

  def initialize(@body : String = "hello q=hello world")
    @server = TCPServer.new("127.0.0.1", 0)
    @closed = false
    spawn do
      while conn = @server.accept?
        serve(conn)
      end
    rescue
      # the listener was closed under the accept loop — that is the teardown path
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

  # `serve(conn)` rather than `spawn do … conn … end` at the accept site: a block there would
  # capture the LOOP VARIABLE and two probes arriving back to back would both be answered on
  # the second socket (see `spawn_with` in spec_helper).
  private def serve(conn : TCPSocket) : Nil
    spawn do
      first = conn.gets("\r\n", chomp: true)
      @hits += 1 if first
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

# A captured flow ON the counting origin, so an active probe of it is a request the origin
# counts. `q=hello` is there to give the injection rules a parameter to work on — a flow with
# no input surface is probed with fewer requests, and the point of these examples is the
# difference between one flow's probes and three.
private def seed_probe_flow(store : Gori::Store, port : Int32, target : String) : Int64
  head = "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 19\r\n\r\n".to_slice,
    body: "hello q=hello world".to_slice, duration_us: 1_000_i64))
  store.flush
  id
end

private def three_flows(store : Gori::Store, port : Int32) : Array(Int64)
  %w[/a /b /c].map { |p| seed_probe_flow(store, port, "#{p}?q=hello") }
end

private def scan(store : Gori::Store, ids : Array(Int64), stop : Proc(Bool)?) : Array(Gori::Probe::Detection)
  Gori::Probe::Scan.scan_flows(store, ids, active: true, verify_upstream: false,
    allow_unscoped: true, stop: stop)
end

describe "Gori::Probe::Scan cooperative stop" do
  it "sends nothing at all when the caller has already stopped" do
    origin = CountingOrigin.new
    begin
      with_store do |store|
        ids = three_flows(store, origin.port)
        dets = scan(store, ids, -> { true })
        origin.hits.should eq(0) # the measurement: not one probe reached the origin
        # …and the request-free half did not run either: a stop is the caller saying the scan
        # is over, not "skip the sends". Nothing was read, so nothing was found.
        dets.should be_empty
      end
    ensure
      origin.close
    end
  end

  it "stops sending after the flow that was in flight, instead of probing the rest" do
    control = CountingOrigin.new
    stopped = CountingOrigin.new
    begin
      full = 0
      with_store do |store|
        ids = three_flows(store, control.port)
        scan(store, ids, nil)
        full = control.hits
      end
      # Guard the guard: three flows of active probes are many requests, or this example is
      # measuring nothing.
      full.should be > 9

      with_store do |store|
        ids = three_flows(store, stopped.port)
        # Armed by the ORIGIN's own counter, so the cancel lands mid-scan at a point the
        # example does not have to time: the first probe to arrive stops the run.
        scan(store, ids, -> { stopped.hits >= 1 })
        # One flow's probes, not three. The bound is "at most one more flow" — a probe already
        # on the socket owns its own timeout — so this is the difference the stop buys.
        stopped.hits.should be > 0          # it really did start sending…
        (stopped.hits * 2).should be < full # …and it stopped long before the end
      end
    ensure
      control.close
      stopped.close
    end
  end

  it "stops the repeater half on the same signal the flow half reads" do
    origin = CountingOrigin.new
    begin
      with_store do |store|
        store.insert_repeater("http://127.0.0.1:#{origin.port}/r",
          "GET /r?q=hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n\r\n".to_slice,
          false, true, nil, 0)
        # One budget is shared across the halves, so a stop that bound only the flow loop
        # would let the repeater loop spend what the flows had left.
        dets, n = Gori::Probe::Scan.scan_repeaters(store, active: true, verify_upstream: false,
          allow_unscoped: true, stop: -> { true })
        origin.hits.should eq(0)
        n.should eq(0)
        dets.should be_empty
      end
    ensure
      origin.close
    end
  end

  # `scan_all` is the entry point every headless surface uses, and the stop has to short it
  # END TO END — both halves plus the out-of-band promotion, which is the one pass this module
  # runs unconditionally today. That promotion writes `probe_issues` rows, and a stopped run
  # must not write them behind a caller that has walked away: it exists to put those findings
  # in THIS run's report, and a cancelled MCP call is owed no report at all.
  it "short-circuits scan_all, findings and all, when the run was stopped" do
    origin = CountingOrigin.new
    begin
      with_store do |store|
        # A secret in the query string, so the PASSIVE half has something to find: the control
        # below has to find it, or the empty result after it proves nothing.
        ids = [seed_probe_flow(store, origin.port, "/d?token=aaaaaaaaaaaa")]
        Gori::Probe::Scan.scan_all(store, ids, active: false)[0].should_not be_empty
        dets, n = Gori::Probe::Scan.scan_all(store, ids, active: false, stop: -> { true })
        dets.should be_empty
        n.should eq(0)
      end
    ensure
      origin.close
    end
  end
end
