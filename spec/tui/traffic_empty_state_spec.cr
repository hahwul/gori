require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::TrafficEmptyState do
  it "renders the history flow-log card with listen address and Open browser" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: {"127.0.0.1", 8070}, capturing: true)
    backend.contains?("waiting for traffic").should be_true
    backend.contains?("FLOW LOG").should be_true
    backend.contains?("localhost:8070").should be_true
    backend.contains?("Open browser").should be_true
    backend.contains?("──►").should be_true
    backend.contains?("SITE MAP").should be_false
  end

  it "renders the sitemap site-map card with tree hints" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :sitemap, listen: {"0.0.0.0", 9090}, capturing: true)
    backend.contains?("no traffic captured").should be_true
    backend.contains?("SITE MAP").should be_true
    # A wildcard bind must NOT be shown as "0.0.0.0:9090" here — this card is the
    # onboarding surface and that address is the one the user is told to type. The full
    # card has room for the note that LAN devices can reach the listener too.
    backend.contains?("0.0.0.0").should be_false
    backend.contains?("localhost:9090 (all interfaces)").should be_true
    backend.contains?("hosts group traffic").should be_true
    backend.contains?("paths nest").should be_true
    backend.contains?("FLOW LOG").should be_false
  end

  it "shows a capture-off hint when not capturing" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: {"127.0.0.1", 8070}, capturing: false)
    backend.contains?("capture is OFF").should be_true
    backend.contains?("press c").should be_true
  end

  it "degrades history to compact stream lines on a narrow pane" do
    backend = MemoryBackend.new(34, 6)
    rect = Rect.new(0, 0, 34, 6)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: {"10.0.0.5", 3128}, capturing: true)
    backend.contains?("waiting for traffic").should be_true
    backend.contains?("10.0.0.5:3128").should be_true
    backend.contains?("──►").should be_true
    backend.contains?("FLOW LOG").should be_false
  end

  it "degrades sitemap to compact tree lines on a narrow pane" do
    backend = MemoryBackend.new(34, 6)
    rect = Rect.new(0, 0, 34, 6)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :sitemap, listen: {"10.0.0.5", 3128}, capturing: true)
    backend.contains?("no traffic captured").should be_true
    backend.contains?("◆ proxy").should be_true
    backend.contains?("host tr").should be_true # truncated on narrow panes
  end

  it "drops only the wildcard note on a narrow pane, never the address" do
    # The compact fallbacks inline the address into a longer hint line, so they take the
    # terse render. The ADDRESS still matches the full card's — a resize must not look
    # like the proxy moved, and must never fall back to the undialable "0.0.0.0".
    backend = MemoryBackend.new(34, 6)
    rect = Rect.new(0, 0, 34, 6)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :history, listen: {"0.0.0.0", 9090}, capturing: true)
    backend.contains?("localhost:9090").should be_true
    backend.contains?("0.0.0.0").should be_false
    backend.contains?("all interfaces").should be_false
  end

  it "renders the intercept hold-queue card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :intercept, listen: {"127.0.0.1", 8070}, capturing: true, catch_on: false)
    backend.contains?("no held messages").should be_true
    backend.contains?("INTERCEPT").should be_true
    backend.contains?("press i").should be_true
    backend.contains?("i:CATCH").should be_true
  end

  it "renders the repeater resend card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :repeater)
    backend.contains?("no repeater open").should be_true
    backend.contains?("REPEATER").should be_true
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
    # "FUZZ RUN", not "RESULTS": this card draws inside the pane the Fuzzer titles RESULTS, and
    # a card wearing its container's name reads as a rendering fault rather than as a hint.
    backend.contains?("FUZZ RUN").should be_true
    backend.contains?("^R").should be_true
  end

  it "renders the probe scan card when scanning is on" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :probe, listen: {"127.0.0.1", 8070}, capturing: true, scan_on: true)
    backend.contains?("no issues yet").should be_true
    backend.contains?("PROBE").should be_true
    backend.contains?("scan").should be_true
    backend.contains?("m:MODE").should be_true
  end

  it "renders the probe off card when scanning is disabled" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :probe, scan_on: false, title: "scanning is OFF")
    backend.contains?("scanning is OFF").should be_true
    backend.contains?("PROBE").should be_true
    backend.contains?("turn scanning on").should be_true
    backend.contains?("m:MODE").should be_true
  end

  it "renders the issues triage card" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect, variant: :issues)
    backend.contains?("no issues yet").should be_true
    backend.contains?("ISSUES").should be_true
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

  # The four engine tabs whose "nothing open yet" state used to be one muted line, while their
  # siblings (Repeater, Fuzzer) reached this module from the identical container-level branch.
  # Discover is the sharpest case: it sits in the same tab as Sitemap, which has always drawn a
  # card here.
  it "renders the discover crawl card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :discover)
    # "no runs" is the phrase the pane has always used, so a reader of either form sees the same
    # claim — and spec/tui/discover_runs_pane_spec.cr asserts it through the view.
    backend.contains?("no runs").should be_true
    backend.contains?("DISCOVER").should be_true
    backend.contains?("crawl").should be_true
    backend.contains?("Discover here").should be_true
  end

  it "renders the comparer diff card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :comparer)
    backend.contains?("nothing to compare").should be_true
    backend.contains?("COMPARER").should be_true
    backend.contains?("pick flow A").should be_true
    backend.contains?("pick flow B").should be_true
  end

  it "renders the miner hidden-parameter card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :miner)
    backend.contains?("no mining session").should be_true
    backend.contains?("MINER").should be_true
    backend.contains?("Mine parameters").should be_true
    backend.contains?("^R").should be_true
  end

  it "renders the sequencer token card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :sequencer)
    backend.contains?("no sequencer session").should be_true
    backend.contains?("SEQUENCER").should be_true
    backend.contains?("entropy").should be_true
    backend.contains?("Send to Sequencer").should be_true
  end

  # OAST was the last workbench tab with no card at all — an empty CALLBACKS pane is the tallest
  # void in the app, and its loop is the one hardest to guess, since the thing you are waiting
  # for arrives on a channel you never opened.
  it "renders the oast callback card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :oast)
    backend.contains?("no callbacks yet").should be_true
    backend.contains?("OAST").should be_true
    backend.contains?("callback").should be_true
    backend.contains?("get a payload URL").should be_true
    backend.contains?("start listening").should be_true
  end

  # With nothing configured, `g` refuses ("no enabled provider — add one in the Providers tab"),
  # so leading with it would hand the operator a dead end as step one.
  it "leads with the Providers sub-tab when no provider is configured" do
    backend = MemoryBackend.new(60, 13)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 13),
      variant: :oast, has_provider: false)
    backend.contains?("no provider yet").should be_true
    backend.contains?("Providers").should be_true
    backend.contains?("interactsh").should be_true
    backend.contains?("start listening").should be_false
  end

  # The two results-pane variants. Both draw INSIDE a pane that is already a card, so they take
  # `fuzzer_results`' compact shape and a name that is not their container's.
  it "renders the miner run card in an empty findings pane" do
    backend = MemoryBackend.new(60, 10)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 10),
      variant: :miner_results, running: false)
    backend.contains?("no run yet").should be_true
    backend.contains?("MINE RUN").should be_true
    backend.contains?("start mining").should be_true
    backend.contains?("FINDINGS").should be_false # never its container's name
  end

  it "renders the sequencer run card in an empty samples pane" do
    backend = MemoryBackend.new(60, 10)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 10),
      variant: :sequencer_samples, running: false)
    backend.contains?("no samples yet").should be_true
    backend.contains?("TOKEN RUN").should be_true
    backend.contains?("collect samples").should be_true
    backend.contains?("SAMPLES").should be_false
  end

  # Running is a different sentence and drops the chord — the run is already going, so "^R start
  # mining" would be an instruction to do what is happening.
  {% for variant, chord in {miner_results: "start mining", sequencer_samples: "collect samples"} %}
    it "drops the run chord while {{ variant.id }} is in flight" do
      backend = MemoryBackend.new(60, 10)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 10),
        variant: {{ variant.symbolize }}, running: true)
      backend.contains?({{ chord }}).should be_false
    end
  {% end %}

  # Each new variant must degrade like the older ones. A variant added to `render_full` but not
  # to the medium/minimal dispatches falls through to `else`, which prints the headline and
  # nothing else — passing any test that only checks the full card.
  {% for variant in [:discover, :comparer, :miner, :sequencer, :oast] %}
    it "degrades {{ variant.id }} to compact lines on a narrow pane" do
      backend = MemoryBackend.new(34, 6)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 34, 6), variant: {{ variant }})
      rows = (0...6).map { |y| backend.row(y) }
      rows.count { |r| !r.strip.empty? }.should be >= 2 # headline + at least the diagram line
      backend.contains?("──►").should be_true           # the diagram, not just the headline
    end
  {% end %}

  # The results-pane variants carry no diagram (they are compact by design), so the check is
  # that they still say what to press rather than falling through to a bare headline.
  {% for variant, chord in {miner_results: "^R", sequencer_samples: "^R"} %}
    it "degrades {{ variant.id }} to a chord, not just a headline" do
      backend = MemoryBackend.new(34, 6)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 34, 6),
        variant: {{ variant.symbolize }})
      rows = (0...6).map { |y| backend.row(y) }
      rows.count { |r| !r.strip.empty? }.should be >= 2
      backend.contains?({{ chord }}).should be_true
    end
  {% end %}

  it "degrades to a two-line hint on a very small pane" do
    backend = MemoryBackend.new(38, 3)
    rect = Rect.new(0, 0, 38, 3)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :sitemap, listen: {"127.0.0.1", 8070}, capturing: false)
    backend.contains?("no traffic captured").should be_true
    backend.contains?("◆ proxy").should be_true
    backend.contains?("^P Open br").should be_true # truncated on narrow panes
  end
end
