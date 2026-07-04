require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::TrafficEmptyState do
  it "renders the history flow-log card with listen address and Open browser" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: "127.0.0.1:8070", capturing: true)
    backend.contains?("waiting for traffic").should be_true
    backend.contains?("FLOW LOG").should be_true
    backend.contains?("127.0.0.1:8070").should be_true
    backend.contains?("Open browser").should be_true
    backend.contains?("──►").should be_true
    backend.contains?("SITE MAP").should be_false
  end

  it "renders the sitemap site-map card with tree hints" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :sitemap, listen: "0.0.0.0:9090", capturing: true)
    backend.contains?("no traffic captured").should be_true
    backend.contains?("SITE MAP").should be_true
    backend.contains?("0.0.0.0:9090").should be_true
    backend.contains?("hosts group traffic").should be_true
    backend.contains?("paths nest").should be_true
    backend.contains?("FLOW LOG").should be_false
  end

  it "shows a capture-off hint when not capturing" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: "127.0.0.1:8070", capturing: false)
    backend.contains?("capture is OFF").should be_true
    backend.contains?("press c").should be_true
  end

  it "degrades history to compact stream lines on a narrow pane" do
    backend = MemoryBackend.new(34, 6)
    rect = Rect.new(0, 0, 34, 6)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: "10.0.0.5:3128", capturing: true)
    backend.contains?("waiting for traffic").should be_true
    backend.contains?("10.0.0.5:3128").should be_true
    backend.contains?("──►").should be_true
    backend.contains?("FLOW LOG").should be_false
  end

  it "degrades sitemap to compact tree lines on a narrow pane" do
    backend = MemoryBackend.new(34, 6)
    rect = Rect.new(0, 0, 34, 6)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :sitemap, listen: "10.0.0.5:3128", capturing: true)
    backend.contains?("no traffic captured").should be_true
    backend.contains?("◆ proxy").should be_true
    backend.contains?("host tr").should be_true # truncated on narrow panes
  end

  it "renders the intercept hold-queue card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :intercept, listen: "127.0.0.1:8070", capturing: true, catch_on: false)
    backend.contains?("no held messages").should be_true
    backend.contains?("INTERCEPT").should be_true
    backend.contains?("press i").should be_true
    backend.contains?("i:CATCH").should be_true
  end

  it "renders the replay resend card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :replay)
    backend.contains?("no replay open").should be_true
    backend.contains?("REPLAY").should be_true
    backend.contains?("edit").should be_true
    backend.contains?("^R").should be_true
  end

  it "renders the fuzzer probe card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :fuzzer)
    backend.contains?("no fuzz session").should be_true
    backend.contains?("FUZZER").should be_true
    backend.contains?("§").should be_true
    backend.contains?("⇧I").should be_true
  end

  it "renders the fuzzer results card while idle" do
    backend = MemoryBackend.new(50, 8)
    rect = Rect.new(0, 0, 50, 8)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :fuzzer_results, running: false)
    backend.contains?("no results yet").should be_true
    backend.contains?("RESULTS").should be_true
    backend.contains?("^R").should be_true
  end

  it "renders the prism scan card when scanning is on" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :prism, listen: "127.0.0.1:8070", capturing: true, scan_on: true)
    backend.contains?("no issues yet").should be_true
    backend.contains?("PRISM").should be_true
    backend.contains?("scan").should be_true
    backend.contains?("m:MODE").should be_true
  end

  it "renders the prism off card when scanning is disabled" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :prism, scan_on: false, title: "scanning is OFF")
    backend.contains?("scanning is OFF").should be_true
    backend.contains?("PRISM").should be_true
    backend.contains?("turn scanning on").should be_true
    backend.contains?("m:MODE").should be_true
  end

  it "renders the findings triage card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :findings)
    backend.contains?("no findings yet").should be_true
    backend.contains?("FINDINGS").should be_true
    backend.contains?("⇧F").should be_true
    backend.contains?("triage").should be_true
  end

  it "renders the notes scratchpad card centred in the pane" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :notes)
    backend.contains?("NOTES").should be_true
    backend.contains?("scratchpad").should be_true
    backend.contains?("^N").should be_true
  end

  it "degrades to a two-line hint on a very small pane" do
    backend = MemoryBackend.new(38, 3)
    rect = Rect.new(0, 0, 38, 3)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :sitemap, listen: "127.0.0.1:8070", capturing: false)
    backend.contains?("no traffic captured").should be_true
    backend.contains?("◆ proxy").should be_true
    backend.contains?("^P Open br").should be_true # truncated on narrow panes
  end
end