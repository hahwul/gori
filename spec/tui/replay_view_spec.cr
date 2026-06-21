require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def replay_tmp_store(&)
  path = File.tempname("gori-rv", ".db")
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

describe Gori::Tui::ReplayView do
  it "load_blank seeds an editable, sendable scaffold (no source flow)" do
    view = ReplayView.new
    view.load_blank
    view.loaded?.should be_true
    view.http2?.should be_false
    view.focus.should eq(:target) # new requests start on the target (you change the URL first)

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("https://example.com").should be_true # target field
    backend.contains?("GET / HTTP/1.1").should be_true      # scaffold request line
    backend.contains?("Host: example.com").should be_true   # scaffold header
    backend.contains?("— not sent — press ^R to replay —").should be_true
  end

  it "stays in plain response mode after sending a blank (nothing to diff against)" do
    view = ReplayView.new
    view.load_blank
    ok = Gori::Replay::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus.should eq(:target) # send keeps the current focus (was :target from load_blank)

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
    # the "response" toggle is the active (bright) segment — i.e. NOT the diff view
    ry = (0...20).find { |y| backend.row(y).includes?("response") }.not_nil!
    rx = backend.row(ry).index("response").not_nil!
    backend.fg_at(rx, ry).should eq(Theme::TEXT_BRIGHT)
    dx = backend.row(ry).index("diff").not_nil!
    backend.fg_at(dx, ry).should eq(Theme::MUTED) # diff segment inactive
  end

  it "explains there is nothing to diff when a blank's response pane is toggled to diff" do
    view = ReplayView.new
    view.load_blank
    ok = Gori::Replay::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.toggle_resp_mode # response → diff

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("first send").should be_true # no previous response to diff against yet
    backend.contains?("+ PONG").should be_false    # not shown as a spurious addition
  end

  it "diffs the latest response against the PREVIOUS send (not just the original)" do
    view = ReplayView.new
    view.load_blank
    first = Gori::Replay::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "ONE".to_slice, nil, 1000_i64)
    view.apply(first) # first send: nothing to diff against yet → response mode
    view.focus.should eq(:target)
    view.toggle_resp_mode # user opens the diff tab

    second = Gori::Replay::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "TWO".to_slice, nil, 1000_i64)
    view.apply(second) # second send keeps the diff tab (last-open) → diffs vs the first send

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("- ONE").should be_true # previous response body removed
    backend.contains?("+ TWO").should be_true # current response body added
  end

  it "keeps the last-open response tab on send (does not auto-jump to diff)" do
    replay_tmp_store do |store|
      # A History-loaded flow is diffable from the very first send (baseline = the
      # captured original), which used to force the diff tab open on send.
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: Bytes.empty))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ORIG".to_slice))
      view = ReplayView.new
      view.load(store.get_flow(id).not_nil!)

      ok = Gori::Replay::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "NEW".to_slice, nil, 1000_i64)
      view.apply(ok) # send: must stay on response (the last-open tab), not jump to diff

      backend = MemoryBackend.new(120, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
      backend.contains?("NEW").should be_true
      ry = (0...20).find { |y| backend.row(y).includes?("response") }.not_nil!
      rx = backend.row(ry).index("response").not_nil!
      backend.fg_at(rx, ry).should eq(Theme::TEXT_BRIGHT) # response tab active
      dx = backend.row(ry).index("diff").not_nil!
      backend.fg_at(dx, ry).should eq(Theme::MUTED) # diff tab NOT auto-opened
    end
  end

  it "drops back to response when an errored send can't render the held diff tab" do
    view = ReplayView.new
    view.load_blank
    first = Gori::Replay::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "ONE".to_slice, nil, 1000_i64)
    view.apply(first)
    view.toggle_resp_mode # open the diff tab
    err = Gori::Replay::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
    view.apply(err) # errored send: fall back so the error is visible in the response view

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("replay error: connection refused").should be_true
    ry = (0...20).find { |y| backend.row(y).includes?("response") }.not_nil!
    rx = backend.row(ry).index("response").not_nil!
    backend.fg_at(rx, ry).should eq(Theme::TEXT_BRIGHT)
  end

  it "auto-updates an existing Content-Length to match the edited body on send" do
    replay_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/x", http_version: "HTTP/1.1",
        head: "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 99\r\n\r\n".to_slice,
        body: "hello".to_slice)) # stale CL=99, real body is 5 bytes
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      detail = store.get_flow(id).not_nil!

      view = ReplayView.new
      view.load(detail)
      view.auto_content_length?.should be_true # default on
      sent = String.new(view.request_bytes)
      sent.includes?("Content-Length: 5").should be_true   # recomputed to the body size
      sent.includes?("Content-Length: 99").should be_false # stale value replaced

      view.toggle_auto_content_length # off → send byte-exact
      String.new(view.request_bytes).includes?("Content-Length: 99").should be_true
    end
  end

  it "restore re-opens a persisted tab and starts clean (not dirty)" do
    view = ReplayView.new
    view.restore("https://api.test", "POST /x HTTP/1.1\nHost: api.test\n\nbody", true, false)
    view.loaded?.should be_true
    view.target.should eq("https://api.test")
    view.request_text.should eq("POST /x HTTP/1.1\nHost: api.test\n\nbody")
    view.http2?.should be_true
    view.auto_content_length?.should be_false
    view.dirty?.should be_false # synced/restored text must never be re-saved by us
  end

  it "restore with no persisted response starts the pane empty" do
    view = ReplayView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("— not sent — press ^R to replay —").should be_true
  end

  it "restore re-populates a persisted last response (survives a reopen)" do
    view = ReplayView.new
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true,
      head, "RESTORED".to_slice, nil, 1234_i64)
    view.dirty?.should be_false # a restored tab must never be re-saved
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("RESTORED").should be_true
    backend.contains?("— not sent —").should be_false
  end

  it "restore shows a persisted errored send" do
    view = ReplayView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true,
      Bytes.empty, nil, "connect failed: api.test:443", 0_i64)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("replay error: connect failed: api.test:443").should be_true
  end

  it "marks dirty on edits + flag toggles, and clears on restore" do
    view = ReplayView.new
    view.load_blank
    view.dirty?.should be_false # a freshly opened tab is clean (persisted on creation)

    view.focus_first # :target
    view.target_insert('x')
    view.dirty?.should be_true
    view.clear_dirty

    view.pane_advance(1) # :target → :request
    view.edit_insert('y')
    view.dirty?.should be_true
    view.clear_dirty

    view.toggle_auto_content_length
    view.dirty?.should be_true

    view.restore("https://z.test", "GET / HTTP/1.1\n\n", false, true)
    view.dirty?.should be_false
  end
end
