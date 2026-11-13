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
    backend.contains?("SITE MAP").should be_false
  end

  # The beginner's three steps: proxy (address once), HTTPS trust, or the browser that does
  # both. Every palette row reads as a route (`^P` → title), and nothing clips with `…`.
  it "walks the history card through proxy, CA trust and Open browser without clipping" do
    {120, 80}.each do |w|
      backend = MemoryBackend.new(w, 14)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, w, 14),
        variant: :history, listen: {"127.0.0.1", 18997}, capturing: true)
      text = (1...14).join("\n") { |y| backend.row(y) } # row 0 is the "waiting…" headline
      text.scan("localhost:18997").size.should eq(1)
      backend.contains?("set your client's HTTP+HTTPS proxy").should be_true
      backend.contains?("trust gori's CA — browse http://gori.proxy/").should be_true
      backend.contains?("^P → Copy CA certificate path").should be_true
      backend.contains?("^P   → Open browser: proxied, CA trusted").should be_true
      backend.contains?("^P   → Import: HAR, Burp, OpenAPI, cURL").should be_true
      text.includes?('…').should be_false
    end
  end

  # The Import row costs a row the shortest full card does not have: there the card stays
  # and the row goes, rather than the whole card dropping to its three-line form.
  it "keeps the full history card on a pane with no row to spare for Import" do
    backend = MemoryBackend.new(80, 11)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 80, 11),
      variant: :history, listen: {"127.0.0.1", 18997}, capturing: true)
    backend.contains?("FLOW LOG").should be_true
    backend.contains?("Open browser").should be_true
    backend.contains?("Import:").should be_false
  end

  # ...and never on the row the figure needs: at the one height where figure, gap and card
  # fill the body exactly, Import would push the figure out.
  it "gives the Import row only a row neither the card nor its figure wants" do
    TrafficEmptyState.spare_row?(10, 10, 3).should be_false # the card only just fits
    TrafficEmptyState.spare_row?(13, 10, 3).should be_true  # spare, and no room for the figure anyway
    TrafficEmptyState.spare_row?(14, 10, 3).should be_false # figure + gap + card, exactly
    TrafficEmptyState.spare_row?(15, 10, 3).should be_true
    TrafficEmptyState.spare_row?(14, 10, nil).should be_true # a variant with no figure
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
    backend.contains?("tab bar").should be_true
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
    backend.contains?("Holds each matching request here").should be_true
    backend.contains?("catch is OFF — press to start holding").should be_true
    backend.contains?("DIR REQ").should be_true
    backend.contains?("hold requests, responses or both").should be_true
    backend.contains?("f forward · d drop").should be_true
    backend.contains?("condition — only hold matches").should be_true
  end

  # From the tab bar the queue's keys are spelled behind the key that enters it, never bare
  # (`c` there stops capture); `i` is Global and needs no route. Every row fits 80 columns.
  it "routes intercept queue keys through ↓ while the tab bar has focus" do
    {120, 76}.each do |w|
      backend = MemoryBackend.new(w, 13)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, w, 13),
        variant: :intercept, capturing: false, catch_on: false, body_focused: false,
        catch_direction: "REQ")
      backend.contains?("focus body").should be_false
      backend.contains?("DIR REQ").should be_true
      backend.contains?("c:REQ").should be_false
      backend.contains?("↓ then f forward · d drop").should be_true
      # Key column, then label column: the queue keys carry their ↓ route inside the chip.
      row = ->(text : String) { (0...13).map { |y| backend.row(y) }.find!(&.includes?(text)) }
      dir = row.call("DIR REQ — hold requests, responses or both")
      dir.should contain("▸  ↓ c   DIR REQ")
      row.call("condition — only hold matches").should contain("▸  ↓ /   condition")
      catch_row = row.call("catch is OFF")
      catch_row.should contain("▸  i     catch is OFF")
      catch_row.index("catch").should eq(dir.index("DIR REQ"))
      backend.contains?("tab bar").should be_true
      backend.contains?("…").should be_false
    end
  end

  it "routes intercept queue keys through ↓ in the medium unfocused card" do
    backend = MemoryBackend.new(50, 5)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 50, 5),
      variant: :intercept, catch_on: true, body_focused: false)
    backend.contains?("↓ then f forward · d drop · / condition").should be_true
  end

  it "routes the intercept filter key through ↓ in the minimal unfocused card" do
    backend = MemoryBackend.new(50, 4)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 50, 4),
      variant: :intercept, catch_on: true, body_focused: false)
    backend.contains?("i catch · ↓ then / filter").should be_true
  end

  it "does not advertise a send chord on an empty Miner session" do
    [{60, 12}, {60, 6}, {34, 4}].each do |(w, h)|
      backend = MemoryBackend.new(w, h)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, w, h), variant: :miner)
      backend.contains?("^R").should be_false
    end
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
    # Without a step from the view the card does not know whether the tab has sets, so it
    # never orders "add sets, then".
    backend.contains?("Add payload sets").should be_false
  end

  it "marks the first prerequisite a fuzz run still lacks" do
    row = ->(step : TrafficEmptyState::FuzzStep, text : String) do
      backend = MemoryBackend.new(70, 10)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 70, 10), variant: :fuzzer_results, running: false, fuzz_step: step)
      (0...10).map { |y| backend.row(y) }.find!(&.includes?(text))
    end
    row.call(TrafficEmptyState::FuzzStep::Mark, "1 Mark a position").should contain("▸ 1")
    row.call(TrafficEmptyState::FuzzStep::Mark, "2 Add payloads").should_not contain("▸")
    row.call(TrafficEmptyState::FuzzStep::Payloads, "1 Mark a position").should contain("✓ 1")
    row.call(TrafficEmptyState::FuzzStep::Payloads, "2 Add payloads").should contain("▸ 2")
    row.call(TrafficEmptyState::FuzzStep::Run, "2 Add payloads").should contain("✓ 2")
    row.call(TrafficEmptyState::FuzzStep::Run, "3 Run").should contain("▸ 3")
  end

  it "fits every checklist row in the narrowest full fuzzer card" do
    w = TrafficEmptyState::FULL_MIN_W
    backend = MemoryBackend.new(w, 10)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, w, 10), variant: :fuzzer_results, running: false, fuzz_step: TrafficEmptyState::FuzzStep::Mark)
    backend.contains?("^K word").should be_true
    backend.contains?("^L list").should be_true
  end

  it "names the missing prerequisite on a pane too short for the fuzzer card" do
    backend = MemoryBackend.new(60, 3)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 3), variant: :fuzzer_results, running: false, fuzz_step: TrafficEmptyState::FuzzStep::Mark)
    backend.contains?("mark first · ^A auto · ^K word").should be_true
    backend.contains?("^R").should be_false
  end

  it "resolves the idle fuzzer card's run key from the keymap" do
    prev = TrafficEmptyState.registry
    previous = Gori::Settings.keymap_overrides
    begin
      TrafficEmptyState.registry = Gori::Verbs.registry
      Gori::Settings.keymap_overrides = {"fuzz.run" => ["alt-r"]}
      backend = MemoryBackend.new(70, 10)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 70, 10), variant: :fuzzer_results, running: false)
      backend.contains?("Press ⌥R to start a fuzz run").should be_true
    ensure
      TrafficEmptyState.registry = prev
      Gori::Settings.keymap_overrides = previous
    end
  end

  it "renders the probe scan card when scanning is on" do
    backend = MemoryBackend.new(60, 12)
    rect = Rect.new(0, 0, 60, 12)
    TrafficEmptyState.render(Screen.new(backend), rect,
      variant: :probe, listen: {"127.0.0.1", 8070}, capturing: true, scan_on: true)
    backend.contains?("no findings yet").should be_true
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

  # An empty note opens in READ, so the first thing the card has to say is how to write. `^W`
  # (close the note you have not written yet) used to hold that row.
  it "leads the notes card with the keys that start writing" do
    backend = MemoryBackend.new(80, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 80, 12), variant: :notes)
    backend.contains?("i/↵").should be_true
    backend.contains?("start writing").should be_true
    backend.contains?("^W").should be_false
  end

  # From the tab bar or the strip a bare `i` is the Global intercept toggle, so the card names
  # the way into the note instead of a key that would hold all traffic.
  it "routes the notes card through ↵ while the note is not focused" do
    {% for size in [{80, 12}, {34, 6}, {34, 3}] %}
      backend = MemoryBackend.new({{ size[0] }}, {{ size[1] }})
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, {{ size[0] }}, {{ size[1] }}),
        variant: :notes, body_focused: false)
      backend.contains?("↵").should be_true
      backend.contains?("into the note").should be_true
      backend.contains?("start writing").should be_false
    {% end %}
  end

  it "follows a rebound insert key on the notes and Project description cards" do
    prev = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = {"editor.insert" => ["a"]}
      TrafficEmptyState.registry = Gori::Verbs.registry
      {% for variant in [:notes, :project_desc] %}
        {% for size in [{80, 12}, {34, 6}, {34, 3}] %}
          backend = MemoryBackend.new({{ size[0] }}, {{ size[1] }})
          TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, {{ size[0] }}, {{ size[1] }}), variant: {{ variant }})
          backend.contains?("a/↵").should be_true
          backend.contains?("i/↵").should be_false
        {% end %}
      {% end %}
    ensure
      TrafficEmptyState.registry = nil
      Gori::Settings.keymap_overrides = prev
    end
  end

  # Chips differ in width (` ⇧F ` beside ` n `), and a label that started where its own chip
  # ended put a card's two rows a cell apart.
  {% for variant, labels in {issues: {"issue from History flow", "create an issue here"}, project_scope: {"add an include or exclude rule", "rule actions"}, oast: {"get a payload URL (copied)", "start listening"}, sequencer_samples: {"where the token lives", "collect samples"}} %}
    it "starts both {{ variant.id }} labels in one column" do
      backend = MemoryBackend.new(80, 14)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 80, 14), variant: {{ variant.symbolize }})
      cols = { {{ labels[0] }}, {{ labels[1] }} }.map do |label|
        row = (0...14).map { |y| backend.row(y) }.find!(&.includes?(label))
        row.index!(label)
      end
      cols[0].should eq(cols[1])
    end
  {% end %}

  # Either side can be the one still missing, so the short tiers name both picks — and fit
  # the narrowest pane the medium tier is admitted at.
  it "names both Diff picks on the short tiers without clipping" do
    {% for size in [{30, 6}, {30, 3}] %}
      backend = MemoryBackend.new({{ size[0] }}, {{ size[1] }})
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, {{ size[0] }}, {{ size[1] }}), variant: :diff)
      backend.contains?("a baseline · b newer side").should be_true
    {% end %}
  end

  # Target's Diff sub-tab before a baseline is picked: the shared card, not four lines of
  # prose flush against the frame.
  it "renders the retest diff card" do
    backend = MemoryBackend.new(80, 14)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 80, 14), variant: :diff)
    backend.contains?("no baseline picked").should be_true
    backend.contains?("RETEST DIFF").should be_true
    backend.contains?("pick the baseline project").should be_true
    backend.contains?("Nothing is sent").should be_true
  end

  # The three Project list sub-tabs. Each renders inside a card the pane already titled, so the
  # inner card takes a DIFFERENT name (TARGETS / DNS MAP / VARIABLES) rather than echoing the
  # border, and — being CENTERED — draws no headline.
  it "renders the scope targets card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :project_scope)
    backend.contains?("TARGETS").should be_true
    backend.contains?("which hosts you're testing").should be_true
    backend.contains?("include or exclude").should be_true
    backend.contains?("no scope rules yet").should be_false # CENTERED: headline suppressed
  end

  it "renders the host-overrides DNS map card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :project_overrides)
    backend.contains?("DNS MAP").should be_true
    backend.contains?("Pin a hostname").should be_true
    backend.contains?("map a host to an IP").should be_true
  end

  it "renders the env variables card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :project_env)
    backend.contains?("VARIABLES").should be_true
    backend.contains?("reuse across requests").should be_true
    # No `$KEY` in the static copy any more: the two lines that name a TOKEN are built at render
    # time through `Env.spell`, because a frozen `$KEY` here teaches the one spelling that does
    # not resolve under the namespaced grammar. This bullet names no token at all.
    backend.contains?("add a variable").should be_true
    backend.contains?("in a request expands when you send").should be_true
    # The space menu offers only Add here; Change prefix is palette-only (#1282, #1433).
    backend.contains?("Change prefix").should be_true
    backend.contains?("space").should be_false
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
    # Drawn only while there is no run, so it never offers the key that re-runs one.
    backend.contains?("on a History flow").should be_true
    backend.contains?("run the selected crawl").should be_false
  end

  # The menu-only chip is `Hotkeys.menu_chip`'s spelling, never the arrowless ` space > D `.
  it "spells the discover card's menu chip the shared way" do
    prev = TrafficEmptyState.registry
    begin
      TrafficEmptyState.registry = Gori::Verbs.registry
      backend = MemoryBackend.new(60, 12)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :discover)
      backend.contains?(" #{Gori::Hotkeys.menu_chip(Gori::Verbs.registry, "sitemap.discover")} ").should be_true
      backend.contains?(" space ").should be_false
    ensure
      TrafficEmptyState.registry = prev
    end
  end

  # The cards' chord chips are literals until the Runner hands the module a registry; with
  # one, a chip names the key the operator actually bound — including the `KEY:WORD` chips,
  # whose WORD half is a state, not a key.
  it "resolves chord chips through the registry when one is set" do
    prev = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = {"comparer.pick-a" => ["shift-a"], "probe.mode" => ["shift-m"]}
      TrafficEmptyState.registry = Gori::Verbs.registry

      backend = MemoryBackend.new(60, 12)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :comparer)
      backend.contains?("⇧A").should be_true
      backend.contains?("pick flow A").should be_true

      backend = MemoryBackend.new(60, 12)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12),
        variant: :probe, listen: {"127.0.0.1", 8070}, capturing: true, scan_on: true)
      backend.contains?("⇧M:MODE").should be_true
      backend.contains?("m:MODE").should be_false
    ensure
      TrafficEmptyState.registry = nil
      Gori::Settings.keymap_overrides = prev
    end
  end

  # The MEDIUM tier — what a short pane falls back to — was written as literal strings, so
  # shrinking the pane made the rebound key vanish from the same card that had just shown it.
  it "resolves chord chips on the medium cards too" do
    prev = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = {"comparer.pick-a" => ["shift-a"], "capture.toggle" => ["shift-c"]}
      TrafficEmptyState.registry = Gori::Verbs.registry

      backend = MemoryBackend.new(60, 6) # below the comparer card's full height, above MED_MIN_H
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 6), variant: :comparer)
      backend.contains?("⇧A pick flow A").should be_true
      backend.contains?("b pick flow B").should be_true

      backend = MemoryBackend.new(60, 6)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 6),
        variant: :sitemap, listen: {"127.0.0.1", 8070}, capturing: false)
      backend.contains?("press ⇧C to start").should be_true
    ensure
      TrafficEmptyState.registry = nil
      Gori::Settings.keymap_overrides = prev
    end
  end

  # The four Project sub-tab cards were the ones #928 missed: their chips were written as bare
  # literals with no `verb:`, so a rebind reached the status strip beside them (which goes
  # through `keys()`) and not the card. An operator rebinding "Add env var" to `n` then read
  # `a  add a variable` on the only screen that was offering to teach them the key.
  it "resolves the four Project sub-tab chips through the registry too" do
    prev = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = {
        "scope.add-rule"         => ["n"],
        "hostoverride.add-entry" => ["n"],
        "env.add-var"            => ["n"],
        "activity.filter-source" => ["w"],
      }
      TrafficEmptyState.registry = Gori::Verbs.registry
      { {:project_scope, "add an include or exclude rule", "n"},
       {:project_overrides, "map a host to an IP", "n"},
       {:project_env, "add a variable", "n"},
       {:project_activity, "filter by source", "w"},
      }.each do |(variant, label, want)|
        backend = MemoryBackend.new(70, 16)
        TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 70, 16), variant: variant)
        backend.contains?(label).should be_true # the card is on screen at all
        backend.contains?(" #{want} ").should be_true
      end
    ensure
      TrafficEmptyState.registry = nil
      Gori::Settings.keymap_overrides = prev
    end
  end

  # Registry-less renders (every other example in this file, and the view specs) must keep the
  # literal — the fallback is what makes the `verb:` argument safe to add everywhere.
  it "keeps each of those four chips at its literal with no registry set" do
    { {:project_scope, "a"}, {:project_overrides, "a"}, {:project_env, "a"},
     {:project_activity, "s"} }.each do |(variant, want)|
      backend = MemoryBackend.new(70, 16)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 70, 16), variant: variant)
      backend.contains?(" #{want} ").should be_true
    end
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
    backend.contains?("^R").should be_false
  end

  it "renders the sequencer token card" do
    backend = MemoryBackend.new(60, 12)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 60, 12), variant: :sequencer)
    backend.contains?("no sequencer session").should be_true
    backend.contains?("SEQUENCER").should be_true
    backend.contains?("entropy").should be_true
    backend.contains?("Send to Sequencer").should be_true
    # `^R` does nothing without a session, so the card does not name it.
    backend.contains?("^R").should be_false
    backend.contains?("History or Repeater").should be_true
  end

  it "names no run key on the short and narrow sequencer fallbacks either" do
    [{60, 5}, {30, 2}].each do |(w, h)|
      backend = MemoryBackend.new(w, h)
      TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, w, h), variant: :sequencer)
      backend.contains?("^R").should be_false
    end
  end

  # With an empty queue `authorize.run` is unavailable, so the card says what ^R will do once
  # there is something queued instead of offering it as a chip.
  it "names Authorize's run as the step after queueing, not as a key to press now" do
    backend = MemoryBackend.new(80, 14)
    TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 80, 14), variant: :authorize)
    backend.contains?("then ^R replays what has not run").should be_true
  end

  # These three are reached from another tab's Send flow to… card. A bare ` space ` chip named
  # the leader and not the two letters after it.
  it "spells the send-from-History chips with the full menu path" do
    prev = TrafficEmptyState.registry
    begin
      TrafficEmptyState.registry = Gori::Verbs.registry
      {:authorize => "history.authorize", :miner => "history.mine", :sequencer => "history.sequence"}.each do |variant, verb|
        backend = MemoryBackend.new(80, 14)
        TrafficEmptyState.render(Screen.new(backend), Rect.new(0, 0, 80, 14), variant: variant)
        backend.contains?(" #{Gori::Hotkeys.menu_chip(Gori::Verbs.registry, verb)} ").should be_true
        backend.contains?(" space ").should be_false
      end
    ensure
      TrafficEmptyState.registry = prev
    end
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
    # In words as well as by the Ctrl+digit jump, which not every terminal delivers.
    backend.contains?("Providers sub-tab").should be_true
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

  it "routes the sequencer card's c through the body when focus is not in it" do
    # The card is on screen from the tab bar and the sub-tab strip, where a bare `c` is the
    # Global key that stops capture. It spelled `c` either way.
    off = MemoryBackend.new(60, 10)
    TrafficEmptyState.render(Screen.new(off), Rect.new(0, 0, 60, 10),
      variant: :sequencer_samples, running: false, body_focused: false)
    off.contains?("↓ c").should be_true
    inside = MemoryBackend.new(60, 10)
    TrafficEmptyState.render(Screen.new(inside), Rect.new(0, 0, 60, 10),
      variant: :sequencer_samples, running: false, body_focused: true)
    inside.contains?("↓ c").should be_false
    inside.contains?(" c ").should be_true
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
  {% for variant in [:discover, :comparer, :miner, :sequencer, :oast, :project_scope, :project_overrides, :project_env, :diff] %}
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
    backend.contains?("^P → Op").should be_true # truncated on narrow panes
  end
end
