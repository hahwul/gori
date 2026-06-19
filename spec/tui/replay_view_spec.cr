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

    second = Gori::Replay::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "TWO".to_slice, nil, 1000_i64)
    view.apply(second) # second send: auto-lands on diff vs the first send's response

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("- ONE").should be_true # previous response body removed
    backend.contains?("+ TWO").should be_true # current response body added
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
      sent.includes?("Content-Length: 5").should be_true  # recomputed to the body size
      sent.includes?("Content-Length: 99").should be_false # stale value replaced

      view.toggle_auto_content_length # off → send byte-exact
      String.new(view.request_bytes).includes?("Content-Length: 99").should be_true
    end
  end
end
