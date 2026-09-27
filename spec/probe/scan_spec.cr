require "../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

# A key id shaped like a real one and NOT one of AWS's published documentation placeholders,
# which `Secrets::PATTERNS` screens out (mirrors spec/probe_spec.cr's AWS_KEY_ID).
private AWS_KEY_ID = "AKIA" + "3ZQF7XKPL2WVNB6D"

# A completed 101 upgrade — the shape `scan_flows` reads WebSocket frames for.
private def capture_ws_flow(store) : Int64
  head = "GET /ws HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/ws", http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 101,
    head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
    body: nil, reason: "Switching Protocols", content_type: nil, duration_us: 1_i64))
  id
end

# Records HOW the headless scan reads a flow's frame log: `ws_messages` with a nil limit is the
# whole-log read (every frame of a long-lived socket in memory at once, inside the per-flow loop),
# `ws_messages_after` is the paged one. Both delegate rather than raise — `scan_flows` rescues a
# per-flow exception and reports it through `on_error`, so a raising override would be swallowed
# and the spec would pass for the wrong reason.
private class CountingWsStore < Gori::Store
  getter whole_log_reads = 0
  getter batch_sizes = [] of Int32

  def ws_messages(flow_id : Int64, limit : Int32? = nil) : Array(Gori::Store::WsMessage)
    @whole_log_reads += 1 if limit.nil?
    super
  end

  def ws_messages_after(flow_id : Int64, after_id : Int64, limit : Int32) : Array(Gori::Store::WsMessage)
    msgs = super
    @batch_sizes << msgs.size
    msgs
  end
end

private def with_counting_store(&)
  path = File.tempname("gori-probe-scan-ws", ".db")
  store = CountingWsStore.open(path).as(CountingWsStore)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Probe::Scan do
  # `ws_messages`'s limit returns the NEWEST n — it exists to bound the detail VIEW. Reading it
  # capped here made the one-shot headless scan (`gori run probe`, MCP probe_scan) miss every
  # frame before the last window, while the live Analyzer — which pages forward from a per-flow
  # watermark — reported it.
  it "scans EVERY captured WebSocket frame, not just the newest window" do
    with_store do |store|
      fid = capture_ws_flow(store)
      # 250 frames: the secret rides frame 20 — inside the band a newest-200 window (frames
      # 51..250) drops. The Slack token at frame 240 is the control: it is inside that window,
      # so it must be found both before and after the fix.
      250.times do |k|
        payload = case k
                  when  20 then "token=#{AWS_KEY_ID}"
                  when 240 then "token=xoxb-0123456789abcdef"
                  else          "frame#{k}"
                  end
        store.insert_ws_message(fid, "in", 1, payload.to_slice)
      end
      dets = Gori::Probe::Scan.scan_flows(store, [fid], active: false)
      labels = dets.select(&.code.== "secret_in_ws").compact_map(&.evidence)
      labels.should contain("Slack token")       # control: inside the newest-200 window
      labels.should contain("AWS access key id") # the banded secret the cap skipped
    end
  end

  # EVERY frame, a PAGE at a time. Coverage alone cannot tell an unbounded read from a paged one
  # (both find the secret), so this pins the READ SHAPE the live `Analyzer#rescan_ws` has always
  # used: batches from the oldest unscanned id, never the whole log in one read.
  it "pages the frame log instead of materialising it, and still covers every frame" do
    with_counting_store do |store|
      fid = capture_ws_flow(store)
      cap = Gori::Probe::Analyzer::WS_MSG_CAP
      # One full page plus a partial one. The AWS key rides frame 20 (page 1) and again at
      # cap+10 (page 2) — one label per flow either way; the Slack token rides page 2 only, so
      # a pager that stops after its first batch loses it.
      (cap + 50).times do |k|
        payload = case k
                  when 20, cap + 10 then "token=#{AWS_KEY_ID}"
                  when cap + 39     then "token=xoxb-0123456789abcdef"
                  else                   "frame#{k}"
                  end
        store.insert_ws_message(fid, "in", 1, payload.to_slice)
      end
      dets = Gori::Probe::Scan.scan_flows(store, [fid], active: false)
      store.whole_log_reads.should eq 0     # never the entire frame log in one read
      store.batch_sizes.should eq [cap, 50] # a full page, then the remainder, then stop
      labels = dets.select(&.code.== "secret_in_ws").compact_map(&.evidence)
      labels.should contain("AWS access key id") # frame 20 — the early band the old cap skipped
      labels.should contain("Slack token")       # past the first page — paging must not stop early
      # `WsPayloads` keeps its `seen` labels per Context = per BATCH, so paging must not turn one
      # flow's leak into one finding per page (`Group` counts every observation into hit_count).
      labels.count("AWS access key id").should eq 1
    end
  end
end

# Answers every request with a small 200 and records its request line. Loopback-only, reached
# through a host override, so a probe can only arrive here if the scan actually sent it.
private class LineRecorder
  getter lines = [] of String

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    spawn do
      while conn = @server.accept?
        serve(conn)
      end
    rescue
      # closed under the accept loop — teardown
    end
  end

  def port : Int32
    @server.local_address.port
  end

  def close : Nil
    @server.close rescue nil
  end

  private def serve(conn : TCPSocket) : Nil
    spawn do
      if first = conn.gets("\r\n", chomp: true)
        @lines << first
      end
      while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      end
      conn << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      conn.flush rescue nil
      conn.close rescue nil
    rescue
      conn.close rescue nil
    end
  end
end

private def seed_unresolvable(store : Gori::Store, port : Int32, target : String) : Int64
  head = "GET #{target} HTTP/1.1\r\nHost: nonexistent.invalid:#{port}\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "nonexistent.invalid", port: port,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n".to_slice,
    body: "ok".to_slice, duration_us: 1_i64))
  id
end

describe "Probe::Scan active surface dedup" do
  # Repeat captures of one endpoint used to be probed once EACH, and each spent a unit of the
  # active cap — so with MCP's cap of 500, a busy endpoint captured 500 times left every other
  # endpoint unprobed while the scan reported itself complete.
  it "probes a repeated surface once and does not spend the active cap on its repeats" do
    rec = LineRecorder.new
    begin
      with_store do |store|
        ov = Gori::HostOverrides.load(store)
        ov.add("nonexistent.invalid", "127.0.0.1:#{rec.port}").should be_true
        ids = (1..4).map { |i| seed_unresolvable(store, rec.port, "/s?q=v#{i}") }
        ids << seed_unresolvable(store, rec.port, "/t?q=v")
        budget = Gori::Probe::Scan::Budget.new(2)
        Gori::Probe::Scan.scan_flows(store, ids, active: true, verify_upstream: false,
          allow_unscoped: true, active_budget: budget, overrides: ov)
        budget.exhausted?.should be_false
        rec.lines.any?(&.includes?("/t")).should be_true
        # Only the first capture's value went out: the three repeats sent nothing.
        %w[v2 v3 v4].each { |v| rec.lines.any?(&.includes?("q=#{v}")).should be_false }
      end
    ensure
      rec.close
    end
  end
end
