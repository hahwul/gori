require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::ReplayView do
  it "load_blank seeds an editable, sendable scaffold (no source flow)" do
    view = ReplayView.new
    view.load_blank
    view.loaded?.should be_true
    view.http2?.should be_false
    view.focus.should eq(:request)

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
    view.focus.should eq(:response)

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
    backend.contains?("no original response to diff").should be_true
    backend.contains?("+ PONG").should be_false # not shown as a spurious addition
  end
end
