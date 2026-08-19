require "../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow) ---

private def with_store(&)
  path = File.tempname("gori-probe-scan", ".db")
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

# A completed 101 upgrade — the shape `scan_flows` reads WebSocket frames for.
private def capture_ws_flow(store) : Int64
  head = "GET /ws HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/ws", http_version: "HTTP/1.1", head: head.to_slice, body: nil)
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
                  when  20 then "token=AKIAIOSFODNN7EXAMPLE"
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
                  when 20, cap + 10 then "token=AKIAIOSFODNN7EXAMPLE"
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
