require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

private def fuzz_result(idx : Int32, status : Int32?, len : Int32, *,
                        words : Int32 = 40, matched : Bool = false, error : String? = nil) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx.to_i64, ["p#{idx}"], nil, status, len.to_i64, words, 5,
    (1000 + idx * 100).to_i64, error, matched, false, nil)
end

private def loaded_fuzzer : FuzzerView
  view = FuzzerView.new
  view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  view
end

describe "FuzzerView sorted-view throttle" do
  # The memo keys on @results_rev, which bumps per appended result, so a live run rebuilt the
  # sorted view on EVERY frame. Measured at RESULT_CAP: sort_by(:status) is 615µs and 2.54 MB
  # per call, against a ~239µs whole frame — ~50 MB/s of garbage at 20 fps. Rebuilds are now
  # capped at SORT_REFRESH while a run streams.
  it "reuses the sorted view between rebuilds while a run is streaming" do
    view = loaded_fuzzer
    view.begin_run(nil)
    view.cycle_sort # :index -> :status, which is the shape that COPIES
    view.append_result(fuzz_result(0, 500, 10))
    view.selected_result.try(&.status).should eq(500) # builds and stamps the cache

    # 200 sorts ahead of 500, so an unthrottled rebuild would surface it immediately.
    view.append_result(fuzz_result(1, 200, 20))
    view.selected_result.try(&.status).should eq(500)

    # Ending the run drops the throttle: the next read rebuilds and the row appears.
    view.finish_run
    view.selected_result.try(&.status).should eq(200)
  end

  it "keeps the default index view perfectly live, with no throttle at all" do
    # `:index` with no matched-only filter hands back @results ITSELF rather than a copy, so
    # there is nothing to rebuild and nothing to go stale — the reason the throttle is gated
    # on `copies_results?` instead of just on @running.
    view = loaded_fuzzer
    view.begin_run(nil)
    view.append_result(fuzz_result(0, 500, 10))
    view.selected_result.try(&.status).should eq(500)
    view.append_result(fuzz_result(1, 200, 20))
    view.result_count.should eq(2)
    view.selected_result.try(&.status).should eq(500) # index order: the first row is still row 0
  end

  it "rebuilds at once when the operator changes the sort mid-run" do
    # The throttle must not swallow an OPERATOR action: a keypress that changes the view
    # shape has to show its result on the next frame, not up to SORT_REFRESH later.
    view = loaded_fuzzer
    view.begin_run(nil)
    view.cycle_sort # :status
    view.append_result(fuzz_result(0, 500, 10))
    view.append_result(fuzz_result(1, 200, 20))
    view.selected_result.try(&.status).should eq(200)
    view.cycle_sort # :length — a different shape, so the cache key misses immediately
    view.selected_result.try(&.length).should eq(10)
  end
end

# A view with its RESULT detail open on a three-line response body — two marker words on
# separate lines, so a hit-test that lands a row off is visible in what gets copied.
private def detail_open_fuzzer : FuzzerView
  view = loaded_fuzzer
  body = "alpha ONEWORD tail\nbeta TWOWORD tail\ngamma THREEWORD tail"
  r = Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 60_i64, 9, 5, 1000_i64, nil, false, false, nil,
    "HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice)
  view.append_result(r)
  view.open_detail
  view
end

# Screen cell of `word` after one render, so every mouse example inverts against what was
# actually drawn rather than against the layout arithmetic.
private def drawn_cell(view : FuzzerView, rect : Rect, word : String) : {Int32, Int32}
  b = MemoryBackend.new(rect.w, rect.h)
  view.render(Screen.new(b), rect)
  y = (0...rect.h).find { |r| b.row(r).includes?(word) }.not_nil!
  {b.row(y).index(word).not_nil!, y}
end

# A row the run's keep_bodies dropped: no head, no body, no request — the TUI default
# (:matched) leaves EVERY non-matching row in this shape.
private def unretained_result(idx : Int32, payloads : Array(String)) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx.to_i64, payloads, nil, 404, 12_i64, 2, 1, 1000_i64,
    nil, false, false, nil)
end

private def with_fuzz_store(&)
  path = File.tempname("gori-fuzzview", ".db")
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

# Byte offset just past the head/body separator, or 0. Byte-level on purpose: the seed
# text under test is deliberately not valid UTF-8.
private def body_start(s : String) : Int32
  b = s.to_slice
  i = 0
  while i + 3 < b.size
    return i + 4 if b[i] == 0x0d && b[i + 1] == 0x0a && b[i + 2] == 0x0d && b[i + 3] == 0x0a
    i += 1
  end
  0
end

describe Gori::Tui::FuzzerView do
  describe "a failed send's reason" do
    # Fuzz::Engine returns a scope/sandbox refusal as a Result whose `error` carries the
    # reason and whose head is EMPTY — and Matcher#present nils an empty head, so no
    # keep_bodies setting makes it reachable. The detail pane used to print "(response not
    # retained — only matched results keep the response)", blaming a retention policy the
    # TUI does not even expose for a send that never happened. `gori run fuzz` has always
    # appended r.error per row (cli/output.cr); this is the TUI catching up.
    it "names the failure instead of the retention policy" do
      view = loaded_fuzzer
      view.focus_pane(:results)
      view.append_result(fuzz_result(0, nil, 0, error: Gori::Outbound::SANDBOX_SWEEP_ERROR))
      view.detail_plain_lines.first.should eq("(send failed: #{Gori::Outbound::SANDBOX_SWEEP_ERROR})")
    end

    it "still reports a genuinely unretained response as unretained" do
      view = loaded_fuzzer
      view.focus_pane(:results)
      view.append_result(fuzz_result(0, 200, 1200)) # succeeded, but keep_bodies dropped it
      view.detail_plain_lines.first.should contain("response not retained")
    end
  end

  # Round 8 — the h2 `:status` in the row's leftmost column is 200 by definition for every
  # gRPC response, so a fuzzer sweep against a target that PERMISSION_DENIED-ed every call
  # rendered byte-identical rows to one that granted them all. `Fuzz::Result#grpc_status` /
  # `#grpc_message` existed since round 7 (the Fuzzer ENGINE had the fields); this pins that
  # the RESULTS list row — which round 7 never touched — actually renders them.
  describe "gRPC verdict in the results row" do
    it "renders grpc-status/grpc-message, distinguishing a denied call from a granted one" do
      view = loaded_fuzzer
      view.focus_pane(:results)
      view.append_result(Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 12_i64, 2, 1, 1000_i64,
        nil, false, false, nil, grpc_status: 7, grpc_message: "nope; you may not"))
      # Wide enough that the results row is not ellipsis-truncated before the grpc suffix —
      # this pins the RENDERED text, not just that it was drawn somewhere off-screen.
      backend = MemoryBackend.new(220, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 220, 30))
      backend.contains?("grpc 7 PERMISSION_DENIED").should be_true
      backend.contains?("nope; you may not").should be_true
    end

    it "renders a granted call distinctly from a denied one" do
      view = loaded_fuzzer
      view.focus_pane(:results)
      view.append_result(Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 12_i64, 2, 1, 1000_i64,
        nil, false, false, nil, grpc_status: 0, grpc_message: nil))
      backend = MemoryBackend.new(220, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 220, 30))
      backend.contains?("grpc 0 OK").should be_true
      backend.contains?("PERMISSION_DENIED").should be_false
    end

    # Complement: an ordinary (non-gRPC) row is byte-identical to what it was — no new
    # field noise.
    it "leaves a non-gRPC row unchanged" do
      view = loaded_fuzzer
      view.focus_pane(:results)
      view.append_result(fuzz_result(0, 200, 1200))
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("grpc").should be_false
    end
  end

  describe "#auto_mark" do
    # Fuzz::Template.auto_mark is a deliberate no-op once ANY § is present: it will not
    # double-mark, and it must not clear the operator's own markers to re-derive them.
    # The view used to set_text the unchanged string, then COUNT the markers already in it
    # and report them as "auto-marked N positions" — a success sentence for work it did not
    # do. mark_word (^K) next door has always refused honestly; these pin the parity.
    it "reports the positions it actually placed" do
      view = loaded_fuzzer
      view.auto_mark.should eq("auto-marked 1 position")
    end

    it "refuses instead of re-counting when the template is already marked" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.auto_mark.should contain("already marked (1 position)")
      # …and the template is untouched, so the refusal is real, not a silent rewrite.
      view.template_text.should contain("§1§")
    end

    it "says so when there is nothing to mark" do
      view = FuzzerView.new
      view.load_request("https://h", "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.auto_mark.should eq("nothing to auto-mark — no query, cookie or body values found")
    end
  end

  it "CHAIN pane: focus a template marker, type a chain, commit writes it back" do
    view = FuzzerView.new
    # marker at offset 0 → set_text zeroes the cursor, so it sits inside §x§
    view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:template)
    view.chain_pane_active?.should be_false
    view.focus_chain_pane.should be_nil # in a marker → enters the pane
    view.chain_pane_active?.should be_true
    "rot13".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
    # While the chain is focused, the ^Q modal renders over the tab with a transform preview.
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), Rect.new(0, 0, 120, 30))
    grid = (0...30).map { |y| b.row(y) }.join("\n")
    grid.should contain("CHAIN")
    grid.should contain("PREVIEW")
    view.commit_chain_pane
    view.chain_pane_active?.should be_false
    view.template_text.should contain("§x¦rot13§")
    # Committed: the ¦rot13 is concealed inline (only §x§ shows), never the full marker.
    b2 = MemoryBackend.new(120, 30)
    view.render(Screen.new(b2), Rect.new(0, 0, 120, 30))
    grid2 = (0...30).map { |y| b2.row(y) }.join("\n")
    grid2.should contain("§x§")
    grid2.should_not contain("§x¦rot13§")
  end

  it "points a chain-less position at BOTH halves of its setup (^Q and the CONFIG pane)" do
    # A marked position is only half a Fuzzer run: with no payload set in CONFIG the sweep
    # produces nothing, and the two halves live in different panes. The tooltip used to open
    # only for a marker that already HAD a `¦chain` — i.e. never on a freshly auto-marked
    # template, which is every position an operator meets first.
    view = FuzzerView.new
    view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:template) # cursor at offset 0 → inside §x§, which carries no chain
    b = MemoryBackend.new(120, 30)
    view.render(Screen.new(b), Rect.new(0, 0, 120, 30))
    grid = (0...30).map { |y| b.row(y) }.join("\n")
    grid.should contain("no chain yet")
    grid.should contain("^Q edit · ^O sets")
  end

  # `template_scroll_view` used to bail on `template_insert?`, so the wheel died the moment `i`
  # was pressed — the same `unless insert?` the Repeater request pane shed, in the one other
  # pane that had it. `chain_pane_active?` still bails: the ^Q sub-pane owns the wheel then.
  describe "#template_scroll_view" do
    seed = "GET /?x=1 HTTP/1.1\r\nHost: h\r\n" +
           (1..30).map { |i| "X-#{i}: TAG#{i}" }.join("\r\n") + "\r\n\r\n"

    it "scrolls the template in INS as it does in NOR" do
      [true, false].each do |insert|
        view = FuzzerView.new
        view.load_request("https://h", seed, false, "")
        view.focus_pane(:template)
        view.enter_template_insert! if insert
        rect = Rect.new(0, 0, 100, 22)
        view.render(Screen.new(MemoryBackend.new(100, 22)), rect) # the editor learns its height

        40.times { view.template_scroll_view(1) }
        b = MemoryBackend.new(100, 22)
        view.render(Screen.new(b), rect)
        grid = (0...22).map { |y| b.row(y) }.join("\n")
        grid.should contain("TAG30")     # scrolled to the tail…
        grid.should_not contain("TAG1:") # …and off the head
        view.template_insert?.should eq(insert)
      end
    end

    it "leaves the template alone while the ^Q CHAIN sub-pane owns the wheel" do
      view = FuzzerView.new
      view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n" + seed, false, "")
      view.focus_pane(:template)
      view.focus_chain_pane.should be_nil
      rect = Rect.new(0, 0, 100, 22)
      view.render(Screen.new(MemoryBackend.new(100, 22)), rect)

      40.times { view.template_scroll_view(1) }
      b = MemoryBackend.new(100, 22)
      view.render(Screen.new(b), rect)
      (0...22).map { |y| b.row(y) }.join("\n").should contain("§x§") # still on the first row
    end
  end

  it "CHAIN pane: esc discards the edit instead of committing it" do
    view = FuzzerView.new
    view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:template)
    view.focus_chain_pane.should be_nil
    view.chain_pane_active?.should be_true
    "rot13".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
    view.discard_chain_pane # esc path
    view.chain_pane_active?.should be_false
    view.template_text.should contain("§x§")       # unchanged — no ¦chain written
    view.template_text.should_not contain("rot13") # the typed chain was dropped
  end

  describe "marker structure guard (INS editing)" do
    it "auto-escapes a § typed inside a template marker (structure survives)" do
      view = FuzzerView.new
      view.load_request("https://a", "§ab§ HTTP/1.1\r\nHost: a\r\n\r\n", false, "")
      view.focus_pane(:template)
      view.template_move(0, 2) # caret between a and b
      view.template_insert('§')
      view.template_text.lines.first.should eq("§a§§b§ HTTP/1.1")
      Gori::Fuzz::Template.marked_spans(view.template_text).size.should eq(1)
    end

    it "flags a delimiter delete and strips the whole marker to its value on confirm" do
      view = FuzzerView.new
      view.load_request("https://a", "§secret¦base64-encode§ HTTP/1.1\r\nHost: a\r\n\r\n", false, "")
      view.focus_pane(:template)
      view.template_move(0, 1) # caret just past the opening §
      view.marker_break_on_backspace.should eq({0, 22})
      view.strip_marker_span({0, 22})
      view.template_text.lines.first.should eq("secret HTTP/1.1")
      Gori::Fuzz::Template.marked_spans(view.template_text).should be_empty
    end
  end

  it "toggle_http2 flips the transport and retargets the template request-line version" do
    view = loaded_fuzzer
    view.http2?.should be_false
    view.template_text.lines.first.should end_with("HTTP/1.1")

    view.toggle_http2.should be_true
    view.http2?.should be_true
    view.template_text.lines.first.should end_with("HTTP/2")

    view.toggle_http2.should be_false
    view.template_text.lines.first.should end_with("HTTP/1.1")
  end

  it "duplicate_from copies template + config and clears run results" do
    src = loaded_fuzzer
    src.name = "probe"
    src.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a,b,c"))
    src.template_text.should contain("x=1")

    dst = FuzzerView.new
    dst.duplicate_from(src)
    dst.target.should eq(src.target)
    dst.template_text.should eq(src.template_text)
    dst.set_specs.size.should eq(1)
    dst.set_specs[0].value.should eq("a,b,c")
    dst.name.should eq("probe copy")
    dst.running?.should be_false
  end

  describe "CONFIG summary" do
    it "applies a payload set (from the Set overlay) and renders its row" do
      view = loaded_fuzzer
      view.focus_config
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "admin,root,guest"))
      view.set_specs.size.should eq(1)
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("PAYLOAD SETS").should be_true
      backend.contains?("admin,root,guest").should be_true
    end

    it "walks the single row cursor: sets → Add → Mode → Advanced (clamped)" do
      view = loaded_fuzzer
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a"))
      view.focus_config
      view.config_row.should eq(:set)
      view.current_set_index.should eq(0)
      view.form_move(1); view.config_row.should eq(:add)
      view.form_move(1); view.config_row.should eq(:mode)
      view.form_move(1); view.config_row.should eq(:advanced)
      view.form_move(1); view.config_row.should eq(:advanced) # clamped at the last row (Run moved to the TEMPLATE border)
    end

    it "←/→ only cycles Mode — a no-op on every other row (the de-overload)" do
      view = loaded_fuzzer
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a"))
      view.focus_config
      view.config_row.should eq(:set)
      before_mode = view.config.mode
      view.form_adjust(1) # on a set row → inert
      view.config.mode.should eq(before_mode)
      2.times { view.form_move(1) } # set → add → mode
      view.config_row.should eq(:mode)
      view.form_adjust(1)
      view.config.mode.should_not eq(before_mode)
    end

    it "Del removes the focused set" do
      view = loaded_fuzzer
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a"))
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "b"))
      view.set_specs.size.should eq(2)
      view.focus_config # row 0 = the first set
      view.form_delete
      view.set_specs.size.should eq(1)
      view.set_specs.first.value.should eq("b")
    end

    it "run_request_count is P×N for Sniper over the marked positions" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "") # 1 position
      view.apply_set(nil, Gori::Tui::SetSpec.new(:numbers, "1-10:1"))                      # 10 values
      view.run_request_count.should eq(10_i64)
    end

    # run_request_count runs on the render fiber; a wordlist file must never be line-counted
    # there when doing so could freeze (huge file) or block forever (/dev/zero, a FIFO). An
    # uncountable file reports nil (the Run row just omits the count) instead of reading it.
    it "run_request_count omits a wordlist file it can't safely count on the render path" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.new(:file, "/nonexistent/gori-spec-wordlist"))
      view.run_request_count.should be_nil # File.info? → nil → unknown, never a blocking read
    end

    it "advanced_snapshot round-trips through apply_advanced" do
      view = loaded_fuzzer
      snap = view.advanced_snapshot
      edited = Gori::Tui::AdvancedSnapshot.new(
        conc: "50", rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: true, calibrate: snap.calibrate, keep_alive: false, update_cl: snap.update_cl,
        reframe_grpc: snap.reframe_grpc,
        m_status: "200,500", m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex)
      view.apply_advanced(edited)
      back = view.advanced_snapshot
      back.conc.should eq("50")
      back.follow.should be_true
      back.keep_alive.should be_false # on by default; the edit must survive the round-trip
      back.m_status.should eq("200,500")
    end

    # PR 13 — the Fuzzer pane could not reach `reframe_grpc` at all: `gori run fuzz
    # --reframe-grpc` and MCP `reframe_grpc:` set it, the TUI never did, so the same operator
    # gesture produced different bytes on the two surfaces. The engine is unchanged and
    # already pinned byte-for-byte by spec/fuzz/grpc_verdict_spec.cr; what these pin is the
    # SEAM — the overlay's toggle reaching the very `Fuzz::Config` that `build_engine` hands
    # `Plan.build` (and therefore `Fuzz::Generator#emit`).
    it "the advanced toggle puts reframe_grpc on the config Plan.build receives" do
      view = loaded_fuzzer
      view.config.reframe_grpc?.should be_false # the ctor default, and the headless one (P7)
      view.advanced_snapshot.reframe_grpc.should be_false

      snap = view.advanced_snapshot
      view.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: true,
        m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex))
      view.config.reframe_grpc?.should be_true
      view.advanced_snapshot.reframe_grpc.should be_true

      # …and a run actually builds off it. `build_engine` passes `config: @config` straight
      # through, so this is the object the generator reads.
      with_fuzz_store do |store|
        view.auto_mark # ^A: a §position, without which Plan.build refuses the run
        view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "aa"))
        engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
        err.should be_nil
        engine.should_not be_nil
        view.config.reframe_grpc?.should be_true
      end
    end

    it "leaves reframe_grpc off when the toggle is not touched" do
      # The half that matters most: nothing about opening the ADVANCED card, editing an
      # unrelated row, or saving/restoring a session may flip a P7 default ON.
      view = loaded_fuzzer
      snap = view.advanced_snapshot
      view.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: "5", rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: snap.reframe_grpc,
        m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex))
      view.config.reframe_grpc?.should be_false

      dst = FuzzerView.new
      dst.duplicate_from(view) # config_json → apply_config_json
      dst.config.reframe_grpc?.should be_false
    end

    it "carries reframe_grpc across a config_json round-trip once it IS on" do
      src = loaded_fuzzer
      snap = src.advanced_snapshot
      src.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: true,
        m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex))
      dst = FuzzerView.new
      dst.duplicate_from(src)
      dst.config.reframe_grpc?.should be_true
      dst.advanced_snapshot.reframe_grpc.should be_true
    end

    it "persists match/filter words across a config_json round-trip" do
      src = loaded_fuzzer
      snap = src.advanced_snapshot
      src.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: snap.reframe_grpc,
        m_status: snap.m_status, m_size: snap.m_size, m_words: "42", m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: "7", f_regex: snap.f_regex))
      dst = FuzzerView.new
      dst.duplicate_from(src) # duplicate_from restores via apply_config_json(config_json)
      back = dst.advanced_snapshot
      back.m_words.should eq("42")
      back.f_words.should eq("7")
    end
  end

  it "verifies vertical navigation boundaries (template/config/results at_top)" do
    view = loaded_fuzzer
    view.focus_pane(:template)
    view.template_at_top?.should be_true
    view.config_at_top?.should be_true
    view.results_at_top?.should be_true
    view.at_top?.should be_false

    view.focus_pane(:target)
    view.at_top?.should be_true

    view.focus_pane(:config)
    view.config_at_top?.should be_true
    view.form_move(1)
    view.config_at_top?.should be_false

    view.focus_pane(:results)
    view.append_result(fuzz_result(0, 200, 1200))
    view.append_result(fuzz_result(1, 200, 1200))
    view.results_move(1)
    view.results_at_top?.should be_false
    view.results_move(-1)
    view.results_at_top?.should be_true

    view.focus_pane(:results)
    view.pane_advance(-1).should be_true
    view.focus.should eq(:config)
    view.pane_advance(-1).should be_true
    view.focus.should eq(:template)
    view.pane_advance(-1).should be_true
    view.focus.should eq(:target)
  end

  it "label uses the custom name when set, else the template summary" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.label(18).should eq("GET /?x=1") # auto-derived from the request line
    view.name = "auth fuzz"
    view.label(18).should eq("auth fuzz")
    view.name = "   " # blank → revert to the auto label
    view.label(18).should eq("GET /?x=1")
    view.name = nil
    view.label(18).should eq("GET /?x=1")
  end

  it "label truncates a long custom name" do
    view = FuzzerView.new
    view.load_request("https://h", "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.name = "a-very-long-custom-tab-name"
    label = view.label(8)
    label.size.should be <= 8
    label.should end_with("…")
  end

  describe "template marker highlight" do
    it "tints the §…§ marked region (payload + delimiters) with the marker background" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§foo§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      tint = Theme.marker_bg(0) # a unique chromatic blend — no other cell uses it
      tinted = [] of Char
      (0...30).each do |y|
        (0...120).each { |x| tinted << backend.grid[y][x] if backend.bg_at(x, y) == tint }
      end
      tinted.should contain('f') # the "foo" payload value
      tinted.should contain('§') # both delimiters bracketed
    end

    it "does not tint Repeater/Notes editors (opt-in: bg_regions stays empty)" do
      ta = TextArea.new("GET /?x=§foo§ HTTP/1.1")
      backend = MemoryBackend.new(60, 5)
      ta.render(Screen.new(backend), Rect.new(0, 0, 60, 5), cursor: false, highlight: :request)
      marker = Theme.marker_bg(0)
      (0...5).each do |y|
        (0...60).each { |x| backend.bg_at(x, y).should_not eq(marker) }
      end
    end
  end

  describe "DIST sidebar" do
    it "renders a colored status distribution beside the results (lone 500 in red)" do
      view = loaded_fuzzer
      5.times { |i| view.append_result(fuzz_result(i, 200, 1200)) }
      view.append_result(fuzz_result(99, 500, 320))
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("DIST").should be_true
      backend.contains?("200").should be_true
      # the 500 status label appears in the DIST columns (right of results) drawn in red
      found = false
      (0...30).each do |y|
        idx = backend.row(y).index("500")
        next unless idx && idx >= 86 # DIST region (results width ≈ 85)
        backend.fg_at(idx, y).should eq(Theme.red)
        found = true
      end
      found.should be_true
    end

    it "hides the sidebar on a narrow terminal (results take full width)" do
      view = loaded_fuzzer
      3.times { |i| view.append_result(fuzz_result(i, 200, 1200)) }
      backend = MemoryBackend.new(50, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 50, 30))
      # the sidebar CARD (title " DIST ") is gone; the always-on " v:DIST " toggle badge
      # on the RESULTS border is not the sidebar, so match the spaced card title.
      backend.contains?(" DIST ").should be_false
      backend.contains?("RESULTS").should be_true
    end

    it "shows the full distribution even when the results list is matched-filtered" do
      view = loaded_fuzzer
      3.times { |i| view.append_result(fuzz_result(i, 200, 1200, matched: true)) }
      view.append_result(fuzz_result(99, 500, 320, matched: false)) # the anomaly, NOT matched
      view.toggle_matched_only                                      # results list now hides the 500…
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("500").should be_true # …but DIST still surfaces it
    end

    it "v toggles the sidebar off" do
      view = loaded_fuzzer
      view.append_result(fuzz_result(0, 200, 1200))
      view.toggle_dist # hide
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      # sidebar CARD gone; the muted " v:DIST " toggle badge on the RESULTS border remains
      backend.contains?(" DIST ").should be_false
    end
  end

  describe "RESULTS click-to-select" do
    # On a 120×30 render the RESULTS pane sits at (0,15,85,12) → inner (1,16,83,10):
    # the header is on y=16, so row i (sorted index @scroll+i) lands on y=17+i.
    it "maps a click y to the sorted-view row index (header/out-of-range → nil)" do
      view = loaded_fuzzer
      5.times { |i| view.append_result(fuzz_result(i, 200, 1200)) }
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect)
      view.results_row_at(rect, 5, 16).should be_nil # the header row
      view.results_row_at(rect, 5, 17).should eq(0)  # first result
      view.results_row_at(rect, 5, 19).should eq(2)
      view.results_row_at(rect, 5, 21).should eq(4)    # last populated
      view.results_row_at(rect, 5, 22).should be_nil   # past the last row
      view.results_row_at(rect, 5, 10).should be_nil   # up in the TEMPLATE/CONFIG band
      view.results_row_at(rect, 100, 18).should be_nil # over the DIST sidebar
    end

    it "select_result_row picks a row (clamped) without opening detail" do
      view = loaded_fuzzer
      3.times { |i| view.append_result(fuzz_result(i, 200, 1200)) }
      view.render(Screen.new(MemoryBackend.new(120, 30)), Rect.new(0, 0, 120, 30))
      view.select_result_row(2)
      view.results_selected_index.should eq(2)
      view.focus.should_not eq(:detail)
      view.select_result_row(99) # clamps to the last row
      view.results_selected_index.should eq(2)
    end

    # Repeaters FuzzerController#click_results: first click on a row grabs focus + selects
    # it; a second click on the already-selected row (pane already focused) opens detail.
    it "first click selects + focuses, a second click on the same row opens detail" do
      view = loaded_fuzzer
      4.times { |i| view.append_result(fuzz_result(i, 200, 1200)) }
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect)
      view.focus_pane(:template) # start elsewhere in the focus ring
      # First click on row 2 (y=19): focus is not on :results yet → select + focus.
      row = view.results_row_at(rect, 5, 19).not_nil!
      row.should eq(2)
      if view.focus == :results && row == view.results_selected_index
        view.open_detail
      else
        view.focus_pane(:results)
        view.select_result_row(row)
      end
      view.focus.should eq(:results)
      view.results_selected_index.should eq(2)
      # Second click on the same row: now focused + already selected → open detail.
      row2 = view.results_row_at(rect, 5, 19).not_nil!
      if view.focus == :results && row2 == view.results_selected_index
        view.open_detail
      else
        view.focus_pane(:results)
        view.select_result_row(row2)
      end
      view.focus.should eq(:detail)
      view.selected_result.try(&.index).should eq(2)
    end
  end

  describe "result_request_bytes (detail pane + Send to Repeater, #540)" do
    it "hands back the bytes the engine actually sent when the run retained them" do
      view = loaded_fuzzer
      sent = "GET /?x=SENT HTTP/1.1\r\nHost: h\r\n\r\n"
      view.append_result(Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 1200_i64, 40, 5, 1000_i64,
        nil, true, false, nil, "HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, sent.to_slice))
      r = view.selected_result.not_nil!
      String.new(view.result_request_bytes(r)).should eq(sent)

      # …and the detail's REQUEST pane reads from the same method, so what the operator
      # sees is what "Send to Repeater" hands over.
      view.open_detail
      view.detail_step_pane(-1) # :response → :request
      backend = MemoryBackend.new(120, 30)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("GET /?x=SENT HTTP/1.1").should be_true
    end

    it "falls back to re-rendering the template when the row's request was not retained" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.append_result(fuzz_result(0, 404, 12)) # keep_bodies dropped head/body/request
      r = view.selected_result.not_nil!
      # The marked position takes the row's payload, so the row still reads as its own
      # request. WIRE form, not the LF projection: the template is a message, and the
      # fallback must reproduce what the socket would have carried (R5-F1).
      String.new(view.result_request_bytes(r)).should eq("GET /?x=p0 HTTP/1.1\r\nHost: h\r\n\r\n")
    end
  end

  # ── R5-F1 / R5-F2 ──────────────────────────────────────────────────────────────────
  #
  # A captured body carrying a CRLF is the whole point of these: 0x0D 0x0A inside a BODY is
  # data (a CL/TE desync probe, a multipart delimiter, part content, a CRLF-injection test),
  # never a line ending the fuzzer may re-encode. The TUI Fuzzer read `TextArea#text` — the
  # LF projection — on the send path, the persistence path AND every § marking helper, so the
  # capture went out one byte shorter per line with `ContentLength.sync` quietly resyncing the
  # header DOWN to match. Nothing errored. `gori run fuzz` given the same bytes is byte-exact,
  # and so is the Repeater replaying the same flow in the same session.
  describe "byte-exact captured template (R5-F1)" do
    # POST with a deliberate CRLF inside the JSON body. Body is exactly 12 bytes.
    captured = "POST /h1t HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n" \
               "Content-Length: 12\r\n\r\n{\"k\":\"v\r\nx\"}"
    # The same request an operator TYPED — every terminator LF, body has no CR at all.
    # This is the complement: the fix must not go the other way and inject CRLF into a body.
    typed = "POST /h1t HTTP/1.1\nHost: h\nContent-Type: application/json\n" \
            "Content-Length: 11\n\n{\"k\":\"v\nx\"}"

    # Put the caret on the body's `v` (line 5, col 6) — the finding's own repro chord.
    caret_on_body_v = ->(view : FuzzerView) do
      view.focus_pane(:template)
      view.template_move(5, 6)
    end

    it "keeps the body's CRLF through ^K mark word — the chord the repro uses" do
      view = FuzzerView.new
      view.load_request("http://h", captured, false, "")
      caret_on_body_v.call(view)
      view.mark_word.should eq("marked position")
      # The § landed around the body's `v`, and the CRLF that followed it is still a CRLF.
      view.template_text.should eq("POST /h1t HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n" \
                                   "Content-Length: 12\r\n\r\n{\"k\":\"§v§\r\nx\"}")
    end

    it "keeps a hand-typed body's bare LF through ^K — the complement" do
      view = FuzzerView.new
      view.load_request("http://h", typed, false, "")
      caret_on_body_v.call(view)
      view.mark_word.should eq("marked position")
      view.template_text.should eq("POST /h1t HTTP/1.1\nHost: h\nContent-Type: application/json\n" \
                                   "Content-Length: 11\n\n{\"k\":\"§v§\nx\"}")
    end

    it "keeps the body's CRLF through ^A auto-mark and Clear markers" do
      view = FuzzerView.new
      view.load_request("http://h", captured, false, "")
      view.auto_mark.should contain("auto-marked")
      # auto-mark wraps the whole JSON string value, so the CRLF sits INSIDE the marker —
      # a position whose default spans a line break, which is exactly the shape that the
      # LF projection destroyed (`§v\nx§`, one byte short).
      view.template_text.should contain("{\"k\":\"§v\r\nx§\"}")

      view.clear_marks
      view.template_text.should eq(captured) # …and a full round-trip is the identity
    end

    it "persists the template in wire form and round-trips it across a restart" do
      view = FuzzerView.new
      view.load_request("http://h", captured, false, "")
      caret_on_body_v.call(view)
      view.mark_word
      stored = view.template_text # exactly what insert/update_fuzz_session writes

      reopened = FuzzerView.new
      reopened.restore(Gori::Store::FuzzSessionRecord.new(1_i64, "http://h", stored, false, nil,
        "", nil, 0, nil))
      reopened.template_text.should eq(stored)
      # …and the reconcile poll must see them as equal, or it slams the caret every tick.
      reopened.session_side_matches?(Gori::Store::FuzzSessionRecord.new(1_i64, "http://h", stored,
        false, nil, "", nil, 0, nil)).should be_true
    end

    it "puts the captured body on the wire byte-exact, CL and all, end to end" do
      with_fuzz_store do |store|
        scope = Gori::Scope.load(store)
        view = FuzzerView.new
        view.load_request("http://127.0.0.1:1/h1t", captured, false, "")
        caret_on_body_v.call(view)
        view.mark_word
        view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a,bbbbbbbbbb"))

        engine, err = view.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil
        view.begin_run(2_i64)

        # Row 0, payload "a": same length as the default, so the CL is unchanged at 12 —
        # and the body's CRLF is still two bytes. The old code sent 11 with a bare LF.
        view.append_result(unretained_result(0, ["a"]))
        String.new(view.result_request(view.selected_result.not_nil!).bytes)
          .should eq("POST /h1t HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n" \
                     "Content-Length: 12\r\n\r\n{\"k\":\"a\r\nx\"}")

        # Row 1, payload "bbbbbbbbbb": the CL MOVES (12 → 21). 21, not the 20 a flattened
        # body produces — the complement that proves the CRLF is counted as two bytes.
        view.append_result(unretained_result(1, ["bbbbbbbbbb"]))
        view.select_result_row(1)
        String.new(view.result_request(view.selected_result.not_nil!).bytes)
          .should eq("POST /h1t HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n" \
                     "Content-Length: 21\r\n\r\n{\"k\":\"bbbbbbbbbb\r\nx\"}")
      end
    end
  end

  # R5-F2: `Result#request` is nil for every row the run's keep_bodies dropped — and the TUI
  # default is :matched, so that is EVERY non-matching row. The fallback re-rendered the raw
  # template: no Content-Length sync, no per-position chain transform, and no mark saying it
  # was a reconstruction — while the response pane beside it DOES name its own retention,
  # which implies by contrast that the request pane is evidence.
  describe "reconstruction provenance (R5-F2)" do
    marked = "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nv=§x§"

    it "syncs Content-Length on the reconstruction instead of showing an impossible pair" do
      view = FuzzerView.new
      view.load_request("http://h", marked, false, "")
      view.append_result(unretained_result(0, ["ccccccccccccccccccccc"])) # 21 bytes
      req = view.result_request(view.selected_result.not_nil!)
      req.reconstructed.should be_true
      # body is "v=" + 21 = 23. The old fallback left the template's "Content-Length: 3"
      # beside a 23-byte body — a pair no socket ever carried.
      String.new(req.bytes).should eq("POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 23\r\n\r\nv=ccccccccccccccccccccc")
    end

    it "applies the position's ¦chain, as the generator did" do
      view = FuzzerView.new
      view.load_request("http://h", "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nv=§x¦b64§", false, "")
      view.append_result(unretained_result(0, ["bbbbbbbbbb"]))
      body = String.new(view.result_request(view.selected_result.not_nil!).bytes).split("\r\n\r\n", 2)[1]
      body.should eq("v=YmJiYmJiYmJiYg==") # base64("bbbbbbbbbb") — the ¦b64 chain ran
    end

    it "labels the reconstruction in the detail pane, and does NOT label retained bytes" do
      view = FuzzerView.new
      view.load_request("http://h", marked, false, "")
      view.focus_pane(:results)
      view.append_result(unretained_result(0, ["yyy"]))
      view.open_detail
      view.detail_step_pane(-1) # :response → :request
      lines = view.detail_plain_lines
      lines.first.should contain("reconstructed from the template")
      lines.first.should contain("keep_bodies: matched")
      # It reads as a sibling of the response pane's own retention note, not as a new dialect.
      view.detail_step_pane(1)
      view.detail_plain_lines.first.should contain("response not retained")

      # Complement: a row whose request WAS retained carries no note, and no rewriting.
      sent = "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nv=yyy"
      view2 = FuzzerView.new
      view2.load_request("http://h", marked, false, "")
      view2.focus_pane(:results)
      view2.append_result(Gori::Fuzz::Result.new(0_i64, ["yyy"], nil, 200, 5_i64, 1, 1, 10_i64,
        nil, true, false, nil, "HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, sent.to_slice))
      view2.open_detail
      view2.detail_step_pane(-1)
      view2.detail_plain_lines.first.should eq("POST /p HTTP/1.1")
      view2.result_request_note(view2.selected_result.not_nil!).should be_nil
      # …and the operator's deliberate CL/body desync is handed back untouched.
      String.new(view2.result_request(view2.selected_result.not_nil!).bytes).should eq(sent)
    end

    it "carries the caveat into the Repeater seed, and keeps the bytes exact" do
      view = FuzzerView.new
      view.load_request("http://h:80", marked, false, "")
      view.focus_pane(:results)
      view.append_result(unretained_result(0, ["yyy"]))
      seed = FuzzerController.repeater_seed_for(view, view.selected_result.not_nil!)
      seed.note.should_not be_nil
      seed.note.not_nil!.should contain("reconstructed from the template")
      seed.label.should contain("reconstructed")
      # The head keeps its CRLFs — the seed used to collapse them to LF on the premise
      # "Repeater editors store LF text", which the @eols work made false.
      seed.request_text.should contain("POST /p HTTP/1.1\r\nHost: h\r\n")

      # Complement: a retained row seeds with no note and an untouched label.
      view.append_result(Gori::Fuzz::Result.new(1_i64, ["zzz"], nil, 200, 5_i64, 1, 1, 10_i64,
        nil, true, false, nil, "HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty,
        "POST /p HTTP/1.1\r\n\r\nv=zzz".to_slice))
      view.select_result_row(1)
      seed2 = FuzzerController.repeater_seed_for(view, view.selected_result.not_nil!)
      seed2.note.should be_nil
      seed2.label.should eq("#1 zzz")
    end

    it "hands a non-UTF-8 payload byte to the Repeater verbatim instead of U+FFFD" do
      view = FuzzerView.new
      view.load_request("http://h:80", marked, false, "")
      view.focus_pane(:results)
      raw = String.new(Bytes[0xff_u8, 0xfe_u8]) # not valid UTF-8 — a hex/binary payload set
      view.append_result(unretained_result(0, [raw]))
      seed = FuzzerController.repeater_seed_for(view, view.selected_result.not_nil!)
      body = seed.request_text.to_slice[body_start(seed.request_text)..]
      body.should eq(Bytes[0x76_u8, 0x3d_u8, 0xff_u8, 0xfe_u8]) # "v=" + the two raw bytes
      # `.scrub` would have replaced each with U+FFFD (3 bytes each) and lied about the length.
      seed.request_text.should contain("Content-Length: 4")
    end
  end

  # Was "hscroll_detail scrolls a long RESULT response line sideways into view (shift+←/→)". The
  # RESULT detail moved onto the wrapping `ReadPane`, so the whole `hscroll_detail` chain is
  # retired and both ends of an attacker-shaped response line are on screen at once. Still under
  # test: that the tail of a line wider than the pane is reachable — the h-scroll pair's job.
  it "wraps a long RESULT response line instead of scrolling it sideways" do
    view = loaded_fuzzer
    long_line = "HEAD" + ("." * 100) + "TAIL"
    r = Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 1200_i64, 40, 5, 1000_i64, nil, false, false, nil,
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, long_line.to_slice)
    view.append_result(r)
    view.open_detail

    rect = Rect.new(0, 0, 80, 20)
    backend = MemoryBackend.new(80, 20)
    view.render(Screen.new(backend), rect)
    backend.contains?("HEAD").should be_true
    backend.contains?("TAIL").should be_true # on a continuation row, not off the right edge
    head_row = (0...20).find { |y| backend.row(y).includes?("HEAD") }.not_nil!
    tail_row = (0...20).find { |y| backend.row(y).includes?("TAIL") }.not_nil!
    tail_row.should be > head_row
  end
end

describe Gori::Tui::PathComplete do
  it "lists a directory's children, directories trailing a slash" do
    root = File.tempname("gori_pc")
    Dir.mkdir_p(File.join(root, "sub"))
    File.write(File.join(root, "words.txt"), "a\nb\n")
    File.write(File.join(root, "other.lst"), "x\n")
    begin
      pc = PathComplete.new
      pc.refresh("#{root}/")
      pc.open?.should be_true
      file = pc.entries.find { |e| e.label == "words.txt" }.not_nil!
      file.insert.should eq("#{root}/words.txt")
      file.dir.should be_false
      dir = pc.entries.find { |e| e.label == "sub" }.not_nil!
      dir.insert.should eq("#{root}/sub/") # trailing slash so the user keeps drilling
      dir.dir.should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "filters by the typed basename partial" do
    root = File.tempname("gori_pc")
    Dir.mkdir_p(root)
    File.write(File.join(root, "words.txt"), "")
    File.write(File.join(root, "other.txt"), "")
    begin
      pc = PathComplete.new
      pc.refresh("#{root}/wo")
      pc.entries.map(&.label).should eq(["words.txt"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "completes bare names from ~/.gori/wordlists with an ABSOLUTE insert (G1)" do
    home = File.tempname("gori_home")
    wl = File.join(home, "wordlists")
    Dir.mkdir_p(wl)
    File.write(File.join(wl, "rockyou.txt"), "")
    old = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = home
    begin
      pc = PathComplete.new
      pc.refresh("rock")
      hit = pc.entries.find { |e| e.label.starts_with?("rockyou.txt") }.not_nil!
      # The engine opens wordlist paths relative to CWD, so a wordlists-dir-only name
      # MUST resolve absolutely — a bare "rockyou.txt" insert would fail at run time.
      hit.insert.should eq(File.join(wl, "rockyou.txt"))
      hit.label.should contain("·~/.gori")
    ensure
      old ? (ENV["GORI_HOME"] = old) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
    end
  end

  it "accept returns the highlighted insert + dir flag; move clamps at the top" do
    root = File.tempname("gori_pc")
    Dir.mkdir_p(File.join(root, "dir"))
    File.write(File.join(root, "a.txt"), "")
    begin
      pc = PathComplete.new
      pc.refresh("#{root}/")
      pc.move(-1) # clamp at the top
      pc.selected.should eq(0)
      first = pc.entries[0]
      res = pc.accept.not_nil!
      res[0].should eq(first.insert)
      res[1].should eq(first.dir)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "a blank field lists favorites (under a header) before recents, excluding recents already favorited" do
    Gori::Settings.fuzz_favorite_wordlists = ["/wl/fav.txt"]
    Gori::Settings.fuzz_recent_wordlists = ["/wl/fav.txt", "/wl/recent.txt"]
    begin
      pc = PathComplete.new(wordlist_history: true)
      pc.refresh("")
      pc.open?.should be_true
      pc.entries.map(&.label).should eq(["★ Favorites", "/wl/fav.txt", "🕒 Recent", "/wl/recent.txt"])
      # the cursor lands on the first SELECTABLE row, not the header
      pc.selected.should eq(1)
    ensure
      Gori::Settings.fuzz_favorite_wordlists = [] of String
      Gori::Settings.fuzz_recent_wordlists = [] of String
    end
  end

  it "an instance NOT opted into wordlist_history ignores recent/favorite state entirely (Import/CA-import overlays)" do
    home = File.tempname("gori_home_pc_no_history")
    wl = File.join(home, "wordlists")
    Dir.mkdir_p(wl)
    File.write(File.join(wl, "rockyou.txt"), "")
    old = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = home
    Gori::Settings.fuzz_favorite_wordlists = ["/wl/fav.txt"]
    Gori::Settings.fuzz_recent_wordlists = ["/wl/recent.txt"]
    begin
      pc = PathComplete.new # the default — every non-Fuzzer caller (Import, CA Import)
      pc.refresh("")
      pc.open?.should be_true # still opens the plain cwd + ~/.gori/wordlists listing
      pc.entries.map(&.label).should_not contain("★ Favorites")
      pc.entries.map(&.label).should_not contain("🕒 Recent")
      pc.entries.none? { |e| e.label == "/wl/fav.txt" || e.label == "/wl/recent.txt" }.should be_true
    ensure
      old ? (ENV["GORI_HOME"] = old) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
      Gori::Settings.fuzz_favorite_wordlists = [] of String
      Gori::Settings.fuzz_recent_wordlists = [] of String
    end
  end

  it "falls back to the cwd + ~/.gori/wordlists listing when blank with no recent/favorite history yet" do
    home = File.tempname("gori_home_pc_fallback")
    wl = File.join(home, "wordlists")
    Dir.mkdir_p(wl)
    File.write(File.join(wl, "rockyou.txt"), "")
    cwd = File.tempname("gori_pc_fallback_cwd")
    Dir.mkdir_p(cwd)
    old_home = ENV["GORI_HOME"]?
    old_cwd = Dir.current
    ENV["GORI_HOME"] = home
    # An empty, dedicated cwd — the merged cwd + ~/.gori/wordlists list is capped
    # (PathComplete::CAP), so asserting against the REAL repo root (which the
    # process's actual cwd would otherwise be) is one runaway top-level file away
    # from evicting rockyou.txt out of the cap and flaking this assertion.
    Dir.cd(cwd)
    Gori::Settings.fuzz_recent_wordlists = [] of String
    Gori::Settings.fuzz_favorite_wordlists = [] of String
    begin
      pc = PathComplete.new(wordlist_history: true)
      pc.refresh("")
      pc.open?.should be_true
      pc.entries.map(&.label).should_not contain("★ Favorites")
      pc.entries.map(&.label).should_not contain("🕒 Recent")
      pc.entries.any?(&.label.starts_with?("rockyou.txt")).should be_true
    ensure
      Dir.cd(old_cwd)
      old_home ? (ENV["GORI_HOME"] = old_home) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(cwd)
    end
  end

  it "move() steps over header rows in both directions and stops (no-op) at either edge" do
    Gori::Settings.fuzz_favorite_wordlists = ["/wl/fav.txt"]
    Gori::Settings.fuzz_recent_wordlists = ["/wl/recent.txt"]
    begin
      pc = PathComplete.new(wordlist_history: true)
      pc.refresh("") # entries: [Header, fav.txt, Header, recent.txt] · selected = 1
      pc.selected.should eq(1)

      pc.move(-1) # nothing selectable above the Favorites header — no-op
      pc.selected.should eq(1)

      pc.move(1) # fav.txt → skips the "Recent" header → lands on recent.txt
      pc.selected.should eq(3)

      pc.move(1) # already on the last row — no-op
      pc.selected.should eq(3)

      pc.move(-1) # recent.txt → skips the header → back to fav.txt
      pc.selected.should eq(1)
    ensure
      Gori::Settings.fuzz_favorite_wordlists = [] of String
      Gori::Settings.fuzz_recent_wordlists = [] of String
    end
  end

  it "typing even one character drops the recent/favorite view for the usual fuzzy directory search" do
    Gori::Settings.fuzz_favorite_wordlists = ["/wl/fav.txt"]
    Gori::Settings.fuzz_recent_wordlists = ["/wl/recent.txt"]
    begin
      pc = PathComplete.new(wordlist_history: true)
      pc.refresh("x")
      pc.entries.map(&.label).should_not contain("★ Favorites")
      pc.entries.map(&.label).should_not contain("🕒 Recent")
    ensure
      Gori::Settings.fuzz_favorite_wordlists = [] of String
      Gori::Settings.fuzz_recent_wordlists = [] of String
    end
  end
end

# The TEMPLATE editor and the Repeater's request editor are the same `TextArea` holding the
# same captured request, and only one of them could undo or select. An accidental keystroke
# over a seeded template was permanent, and ⇧arrows moved the caret while selecting nothing.
describe "FuzzerView TEMPLATE editor parity with the Repeater request editor" do
  it "⌃Z undoes a typed character (and is a no-op on an empty stack)" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:template)
    view.enter_template_insert!
    view.template_end
    view.template_insert('X')
    view.template_text.split("\r\n")[0].should eq("GET /?x=1 HTTP/1.1X")

    view.template_undo
    view.template_text.split("\r\n")[0].should eq("GET /?x=1 HTTP/1.1")

    before = view.template_text
    10.times { view.template_undo } # empty stack — no crash, no change
    view.template_text.should eq(before)
  end

  it "⇧arrows extend a selection that ⌫ then removes in one step" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:template)
    view.enter_template_insert!
    view.template_home
    view.template_insert_selection?.should be_false
    4.times { view.template_move(0, 1, selecting: true) }
    view.template_insert_selection?.should be_true

    view.template_backspace # removes the SELECTION ("GET "), not one character
    view.template_text.split("\r\n")[0].should eq("/?x=1 HTTP/1.1")

    # …and a plain arrow collapses a selection instead of extending it.
    2.times { view.template_move(0, 1, selecting: true) }
    view.template_move(0, 1)
    view.template_insert_selection?.should be_false
  end
end

describe "FuzzerView#template_click_to_cursor / #target_click_to_cursor" do
  it "places the template caret at the clicked row/column (a later insert lands there)" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    rect = Rect.new(0, 0, 100, 30)
    view.render(Screen.new(MemoryBackend.new(100, 30)), rect)
    # The template card sits below the 3-row target band; row 1 is the "Host: h" line.
    view.template_click_to_cursor(rect, 90, 5) # mx past end → clamps to end of that line
    view.template_insert('X')
    # `template_text` is wire form (R5-F1) — the captured CRLFs are still there, so split
    # on the terminator the request actually carries.
    view.template_text.split("\r\n")[1].should eq("Host: hX")
  end

  it "places the target caret at the clicked column" do
    view = FuzzerView.new
    view.load_request("https://h", "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    rect = Rect.new(0, 0, 100, 30)
    view.render(Screen.new(MemoryBackend.new(100, 30)), rect)
    view.target_click_to_cursor(rect, rect.x + 4 + 3, rect.y + 1) # col 3 of "https://h"
    view.target_insert('X')
    view.target.should eq("httXps://h")
  end

  # The TARGET caret was measured with display_width while BOTH of its counterparts —
  # paint_char_span_bg (the selection tint, in the same render) and Screen.column_for (the
  # click inverse, in target_click_to_cursor) — floor each codepoint to ≥1. On a target
  # holding a zero-width char the three disagreed: the caret sat a column left of its
  # glyph and a click came back one character off. A URL carrying U+200B is not exotic
  # here; it is a stock filter-bypass payload, i.e. exactly what gets pasted into a fuzz
  # target. Pin the round trip: caret column → click at that column → the same index.
  it "keeps the target caret and click-to-cursor agreeing across a zero-width char" do
    target = "https://h/a\u{200B}b" # ZWSP: display_width 0, column_width 1, one drawn cell
    view = FuzzerView.new
    view.load_request(target, "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    rect = Rect.new(0, 0, 100, 30)
    base = rect.x + 4 # render_target draws the value here (the "›" marker sits at rect.x+2)

    view.focus_pane(:target)
    (0..target.size).each do |cx|
      col = base + Screen.draw_width(target[0, cx])
      view.target_click_to_cursor(rect, col, rect.y + 1)
      b = MemoryBackend.new(100, 30)
      view.render(Screen.new(b), rect)
      # The caret is the single cell painted on an accent background in the field.
      caret = (base...(base + 24)).select do |x|
        bg = b.bg_at(x, rect.y + 1)
        bg == Theme.accent || bg == Theme.accent_bg
      end
      caret.should eq([col]) # click column → caret column, with nothing left over
    end

    # …and the click lands on the right CHARACTER, not merely the right column: index 12
    # is the 'b' that sits AFTER the ZWSP, the first index the old measure got wrong.
    fresh = FuzzerView.new
    fresh.load_request(target, "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    fresh.target_click_to_cursor(rect, base + Screen.draw_width(target[0, 12]), rect.y + 1)
    fresh.target_insert('X')
    fresh.target.should eq("#{target[0, 12]}X#{target[12..]}")

    # Concretely: past the ZWSP the old measure was one column short of the drawn glyph.
    Screen.display_width(target).should eq(12)
    Screen.draw_width(target).should eq(13)
  end

  # Same round trip over a MULTI-CODEPOINT cluster, where the retired per-codepoint
  # measure drifted the other way — right, past the end of the drawn text. Only the
  # cluster boundaries are checked: a mid-cluster index is not a caret position a click
  # can produce, since column_for only ever returns cluster starts.
  it "keeps the target caret and click agreeing across a decomposed cluster" do
    target = "https://h/cafe\u{0301}b" # café as e + combining acute
    view = FuzzerView.new
    view.load_request(target, "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    rect = Rect.new(0, 0, 100, 30)
    base = rect.x + 4

    view.focus_pane(:target)
    i = 0
    bounds = [] of Int32
    target.each_grapheme { |g| bounds << i; i += g.size }
    bounds << target.size
    bounds.each do |cx|
      col = base + Screen.draw_width(target[0, cx])
      view.target_click_to_cursor(rect, col, rect.y + 1)
      b = MemoryBackend.new(100, 30)
      view.render(Screen.new(b), rect)
      caret = (base...(base + 24)).select do |x|
        bg = b.bg_at(x, rect.y + 1)
        bg == Theme.accent || bg == Theme.accent_bg
      end
      caret.should eq([col]) # (cx=#{cx})
    end

    # The per-codepoint measure over-counted by one for every combining mark.
    Screen.draw_width(target).should eq(15)
    target.each_char.sum { |c| Screen.draw_width(c.to_s) }.should eq(16)
  end
end

# The RESULT detail paints a selection band, grows it on ⇧arrows and copies it with `y` — and
# the pointer used to do nothing there at all: the controller's drag/double-click arms bailed
# unless the TEMPLATE was focused and its click arm had no `:detail` branch. These pin the view
# half (the controller has no unit harness — it needs a Host).
describe "FuzzerView result-detail mouse" do
  it "places the detail caret at a click and copies the line it landed on" do
    view = detail_open_fuzzer
    rect = Rect.new(0, 0, 110, 30)
    x, y = drawn_cell(view, rect, "TWOWORD")
    view.detail_click_to_cursor(rect, x, y)
    view.detail_copy_text.should contain("TWOWORD") # no selection → the caret's whole line
    view.detail_copy_text.should_not contain("ONEWORD")
  end

  it "takes the word under the pointer on a double-click" do
    view = detail_open_fuzzer
    rect = Rect.new(0, 0, 110, 30)
    x, y = drawn_cell(view, rect, "TWOWORD")
    view.detail_select_word(rect, x + 2, y).should be_true
    view.detail_copy_text.should eq("TWOWORD")
  end

  it "extends the selection to the pointer on a drag" do
    view = detail_open_fuzzer
    rect = Rect.new(0, 0, 110, 30)
    x1, y1 = drawn_cell(view, rect, "ONEWORD")
    view.detail_click_to_cursor(rect, x1, y1) # the press
    x2, y2 = drawn_cell(view, rect, "TWOWORD")
    view.detail_click_to_cursor(rect, x2 + "TWOWORD".size, y2, selecting: true)
    text = view.detail_copy_text
    text.should contain("ONEWORD")
    text.should contain("TWOWORD")
    text.should_not contain("THREEWORD") # the drag stopped on line 2
  end

  it "reports no word on a double-click over whitespace past the line's end" do
    view = detail_open_fuzzer
    rect = Rect.new(0, 0, 110, 30)
    _, y = drawn_cell(view, rect, "TWOWORD")
    view.detail_select_word(rect, 100, y).should be_false
  end

  # The chip strip rides the card's TOP BORDER, drawn by render_detail_chips. It was drawn and
  # dead; the History drill-in's equivalent strip has always been clickable.
  it "switches the detail section from a chip click on the card border" do
    view = detail_open_fuzzer
    rect = Rect.new(0, 0, 110, 30)
    b = MemoryBackend.new(110, 30)
    view.render(Screen.new(b), rect)
    y = (0...30).find { |r| b.row(r).includes?("request") && b.row(r).includes?("response") }.not_nil!
    x = b.row(y).index("response").not_nil!

    view.detail_chip_at(rect, x, y).should eq(:response)
    view.detail_chip_at(rect, b.row(y).index("request").not_nil!, y).should eq(:request)
    view.detail_chip_at(rect, x, y + 1).should be_nil # one row into the text is not the strip

    # open_detail lands on :response, so drive a real transition both ways.
    view.show_detail_pane(:request)
    b2 = MemoryBackend.new(110, 30)
    view.render(Screen.new(b2), rect)
    b2.contains?("ONEWORD").should be_false # the request has no response body in it
    b2.contains?("GET /?x=1").should be_true

    view.show_detail_pane(:response)
    b3 = MemoryBackend.new(110, 30)
    view.render(Screen.new(b3), rect)
    b3.contains?("ONEWORD").should be_true
  end

  # Re-clicking the chip you are already on must keep the pane's state. `detail_step_pane`'s
  # range guard passes for a zero delta, so it re-assigns the same pane and runs its full reset
  # — scroll, h-scroll, caret and both line caches — which would silently throw away the
  # selection the operator had just made.
  it "keeps the caret and the selection when the ACTIVE chip is clicked again" do
    view = detail_open_fuzzer
    rect = Rect.new(0, 0, 110, 30)
    x, y = drawn_cell(view, rect, "TWOWORD")
    view.detail_select_word(rect, x + 2, y).should be_true
    view.detail_copy_text.should eq("TWOWORD")

    view.show_detail_pane(:response) # already showing :response — a re-click
    view.detail_copy_text.should eq("TWOWORD")
  end

  it "answers no chip and no caret move when the detail is not the pane on screen" do
    view = detail_open_fuzzer
    view.focus_pane(:template)
    rect = Rect.new(0, 0, 110, 30)
    view.detail_chip_at(rect, 20, 12).should be_nil
    view.detail_click_to_cursor(rect, 20, 12) # inert rather than hit-testing a card that isn't drawn
    view.detail_select_word(rect, 20, 12).should be_false
  end
end

describe "FuzzerView result-detail decode panes" do
  it "offers a GraphQL pane for a GET GraphQL request and renders the decoded query" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /graphql?query={me{id}} HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.append_result(fuzz_result(1, 200, 12))
    view.open_detail
    view.detail_step_pane(1) # response → graphql
    backend = MemoryBackend.new(120, 30)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("graphql").should be_true  # the pane chip
    backend.contains?("{me{id}}").should be_true # the decoded query
  end

  it "offers a PARAMS pane for a form-encoded POST body" do
    body = "user=admin&pw=secret"
    req = "POST /login HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    view = FuzzerView.new
    view.load_request("https://h", req, false, "")
    view.append_result(fuzz_result(1, 200, 12))
    view.open_detail
    view.detail_step_pane(1) # response → params
    backend = MemoryBackend.new(120, 30)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("params").should be_true
    backend.contains?("user").should be_true
    backend.contains?("admin").should be_true
  end

  it "shows only request/response when the flow carries no decodable protocol" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /plain HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.append_result(fuzz_result(1, 200, 12))
    view.open_detail
    view.detail_step_pane(1) # → response (last pane; a further step is a no-op)
    view.detail_step_pane(1) # clamped
    backend = MemoryBackend.new(120, 30)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("graphql").should be_false
    backend.contains?("params").should be_false
  end

  it "apply_peer_session keeps focus and in-memory results (reconcile soft-sync)" do
    # Regression: full restore() forced focus=:template and would wipe session UI;
    # live data_version reconcile must soft-sync request side only.
    view = FuzzerView.new
    view.load_request("https://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n", false, "")
    view.focus_pane(:results)
    view.append_result(fuzz_result(1, 200, 10))
    view.append_result(fuzz_result(2, 404, 5))
    n = view.@results.size

    rec = Gori::Store::FuzzSessionRecord.new(
      1_i64, "https://peer.test", "GET /peer HTTP/1.1\r\nHost: peer.test\r\n\r\n",
      false, nil, %({"mode":"sniper","concurrency":20}), nil, 0, nil)
    view.apply_peer_session(rec)

    view.focus.should eq(:results)
    view.target.should eq("https://peer.test")
    view.template_text.should contain("/peer")
    view.@results.size.should eq(n)
    view.session_side_matches?(rec).should be_true
  end
end

describe "FuzzerView pretty-printing" do
  it "pretty-prints JSON request template body in-place and preserves markers" do
    view = FuzzerView.new
    view.load_request("https://h", "POST / HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\n\r\n{\"a\":\"§val§\",\"b\":§age§}", false, "")

    view.pretty_print_template.should be_nil # success
    view.template_text.should contain("\"a\": \"§val§\"")
    view.template_text.should contain("\"b\": §age§")
    view.dirty?.should be_true
  end
end

describe "Gori::Tui::FuzzerView matched_count accounting" do
  it "tracks matched results as they stream in" do
    view = loaded_fuzzer
    view.matched_count.should eq(0)
    view.append_result(fuzz_result(0, 200, 100, matched: true))
    view.append_result(fuzz_result(1, 404, 100, matched: false))
    view.append_result(fuzz_result(2, 200, 100, matched: true))
    view.matched_count.should eq(2)
    view.result_count.should eq(3)
  end

  it "decrements when the ring evicts a matched row past RESULT_CAP" do
    view = loaded_fuzzer
    cap = Gori::Tui::FuzzerView::RESULT_CAP
    # Fill exactly to the cap with matched rows, then push unmatched ones in: each append
    # past the cap evicts a matched row off the front, so the count must fall in step.
    cap.times { |i| view.append_result(fuzz_result(i, 200, 100, matched: true)) }
    view.matched_count.should eq(cap)
    view.result_count.should eq(cap)

    10.times { |i| view.append_result(fuzz_result(cap + i, 404, 100, matched: false)) }
    view.result_count.should eq(cap) # ring stays pinned
    view.matched_count.should eq(cap - 10)

    # Drain the rest of the matched rows out of the ring: the count must reach exactly 0 and
    # not undershoot, which is what a decrement on the wrong branch would do.
    (cap - 10).times { |i| view.append_result(fuzz_result(cap + 10 + i, 404, 100, matched: false)) }
    view.matched_count.should eq(0)
    view.result_count.should eq(cap)
  end

  it "resets on a new run" do
    view = loaded_fuzzer
    3.times { |i| view.append_result(fuzz_result(i, 200, 100, matched: true)) }
    view.matched_count.should eq(3)
    view.begin_run(10_i64)
    view.matched_count.should eq(0)
  end
end

describe "Gori::Tui::FuzzerView ⇧I capture seeding" do
  # PROVENANCE, on the Fuzzer's own road into a capture (⇧I from History / Issues evidence).
  # `§` (U+00A7) is ordinary text — a German or legal body carries it constantly — but `#load`
  # dropped the capture's bytes straight into the template buffer, where `§…§` IS the
  # injection-position syntax. So the site's own text became a position the operator never
  # marked, and a run replaced it with every payload in the set. The same line also `.scrub`ed,
  # so a capture that is not valid UTF-8 was rewritten to U+FFFD before the operator saw it —
  # under a Content-Length the plan then resynced to the corruption.
  #
  # RepeaterView solved the sibling case by escaping an inert `§` to the `§§` literal
  # `Fuzz::Template.parse` already defines; this is the same escape at the same kind of seam.
  describe "⇧I: a CAPTURED § is data, not a fuzz position" do
    # `§SEED§` next to every other byte class a template must carry unchanged: a CRLF inside
    # the body, invalid UTF-8, a captured `$TOKEN`, a tab.
    body = IO::Memory.new.tap { |io|
      io << %({"note":"a\r\nb","mk":"§SEED§","env":"$TOKEN","bin":")
      io.write(Bytes[0xFF, 0xFE, 0x01, 0x02])
      io << %(","tab":"\tx"})
    }.to_slice
    head = "POST /seed?q=1 HTTP/1.1\r\nHost: h.test\r\n" \
           "Content-Type: application/json\r\nContent-Length: #{body.size}\r\n" \
           "Connection: close\r\n\r\n"
    wire = head.to_slice.to_a + body.to_a

    seed = ->(store : Gori::Store, b : Bytes, h : String) do
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/seed?q=1", http_version: "HTTP/1.1",
        head: h.to_slice, body: b))
      store.get_flow(id).not_nil!
    end

    it "escapes the capture's § instead of fuzzing the site's own text" do
      with_fuzz_store do |store|
        view = FuzzerView.new
        view.load(seed.call(store, body, head))
        tmpl = Gori::Fuzz::Template.parse(view.template_text)
        tmpl.position_count.should eq(0) # was 1 — `SEED` swept as an injection position
        view.template_text.should contain(%("mk":"§§SEED§§"))
        # …and the template renders back to the captured request BYTE FOR BYTE.
        tmpl.render(tmpl.default_payloads).to_a.should eq(wire)
      end
    end

    it "does not scrub a capture that is not valid UTF-8" do
      with_fuzz_store do |store|
        view = FuzzerView.new
        view.load(seed.call(store, body, head))
        seeded = view.template_text.to_slice
        # `ff fe 01 02` survived — `.scrub` used to make it `ef bf bd ef bf bd 01 02`, four
        # bytes of growth the Content-Length knew nothing about.
        (0..(seeded.size - 4)).any? { |i| seeded[i, 4] == Bytes[0xFF, 0xFE, 0x01, 0x02] }.should be_true
        # Exactly the two doubled § (2 bytes each) separate the buffer from the wire.
        seeded.size.should eq(wire.size + 4)
      end
    end

    it "^A names the literal § rather than reporting nothing to mark" do
      with_fuzz_store do |store|
        view = FuzzerView.new
        view.load(seed.call(store, body, head))
        view.focus_pane(:template)
        # `Template.auto_mark` is a documented no-op once ANY § is in the text, and the escape
        # puts one there. The old "no query, cookie or body values found" line would be a
        # plain untruth about a request with `?q=1` and a JSON body in it.
        msg = view.auto_mark
        msg.should contain("literal")
        msg.should contain("^K")
        view.template_text.should contain(%("mk":"§§SEED§§")) # refused, not silently rewritten
      end
    end

    it "^K still marks a token on the capture, and only that token" do
      with_fuzz_store do |store|
        view = FuzzerView.new
        view.load(seed.call(store, body, head))
        view.focus_pane(:template)
        view.mark_word.should eq("marked position") # cursor at 0 → the METHOD token
        tmpl = Gori::Fuzz::Template.parse(view.template_text)
        tmpl.position_count.should eq(1)
        tmpl.positions[0].default.should eq("POST")
        # The capture's own § stayed literal, and its binary field is still intact.
        String.new(tmpl.render(["GET"])).should contain(%("mk":"§SEED§"))
        rendered = tmpl.render(["POST"])
        rendered.to_a.should eq(wire)
      end
    end

    it "COMPLEMENT: a capture with NO § seeds byte-identically" do
      with_fuzz_store do |store|
        plain = %({"note":"a\r\nb","env":"$TOKEN"}).to_slice
        h = "POST /seed?q=1 HTTP/1.1\r\nHost: h.test\r\nContent-Length: #{plain.size}\r\n\r\n"
        view = FuzzerView.new
        view.load(seed.call(store, plain, h))
        view.template_text.to_slice.to_a.should eq(h.to_slice.to_a + plain.to_a)
        view.auto_mark.should eq("auto-marked 3 positions")
      end
    end

    it "COMPLEMENT: a § the OPERATOR typed still marks and fuzzes" do
      view = FuzzerView.new
      view.load_request("https://h.test", "GET /?x=§1§ HTTP/1.1\r\nHost: h.test\r\n\r\n", false, "")
      Gori::Fuzz::Template.parse(view.template_text).position_count.should eq(1)
    end

    # The `$` half of the same provenance question, and the half evidence used to answer per
    # TAB: an `Authorization: $TOKEN` the operator adds to a seeded template shipped as six
    # literal bytes on every variation of the sweep. Per NAME — the capture's `$TOKEN` above
    # stays literal in the very same template, because that one IS an origin byte.
    it "substitutes a $KEY the operator added to a seeded template, keeping the capture's own literal" do
      Gori::Settings.env_vars = [{"TOKEN", "captured-name"}, {"SESSION", "s3cr3t"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      with_fuzz_store do |store|
        scope = Gori::Scope.load(store)
        view = FuzzerView.new
        view.load(seed.call(store, body, head))
        view.focus_pane(:template)
        view.mark_word # the METHOD token — a plan needs one position
        view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "POST,GET"))
        # The operator adds a header of their own, at the end of the `Host:` line.
        view.template_move(1, 0)
        view.template_end
        view.template_newline
        "Authorization: $SESSION".each_char { |c| view.template_insert(c) }

        engine, err = view.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil
        view.begin_run(3_i64)
        view.append_result(unretained_result(0, ["POST"]))
        wire_out = String.new(view.result_request(view.selected_result.not_nil!).bytes)
        wire_out.should contain("Authorization: s3cr3t") # theirs → expanded
        wire_out.should contain(%("env":"$TOKEN"))       # the capture's → still literal
        wire_out.should_not contain("captured-name")
      end
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end
  end
end

# A fuzz row is exactly the comparison the Comparer tab is for — "this payload got a 500,
# the baseline got a 200, what is different about the body" — and it had no way there: a
# fuzz send is not a captured flow, so neither the flow picker nor History's handoff could
# reach it. See `Gori::Tui::ComparerSlot`.
describe "Gori::Tui::FuzzerController fuzz → Comparer slot" do
  it "carries the sent request, the retained response and the measured meta" do
    view = loaded_fuzzer
    r = Gori::Fuzz::Result.new(4_i64, ["' OR 1=1"], nil, 500, 91_i64, 9, 5, 12_000_i64,
      nil, true, false, nil,
      "HTTP/1.1 500 Internal Server Error\r\n\r\n".to_slice, "stack trace".to_slice,
      "GET /?x=' OR 1=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
    slot = Gori::Tui::FuzzerController.comparer_slot_for(view, r)
    slot.label.should eq("#4 ' OR 1=1")
    slot.method.should eq("GET")
    slot.meta.status.should eq(500)
    slot.meta.duration_us.should eq(12_000)
    slot.meta.size.should eq(91) # the run's measured length, not the held body's
    slot.lines(:response).should contain("stack trace")
    slot.lines(:request).first.should contain("' OR 1=1")
  end

  # `keep_bodies` off is the TUI default, so the common case has no response bytes at all.
  # The slot must still be usable — the request half is reconstructed and the meta was
  # measured either way — and it must SAY that the request is a reconstruction.
  it "still yields a slot for a row the run kept no bodies for, and flags the rebuild" do
    view = loaded_fuzzer
    slot = Gori::Tui::FuzzerController.comparer_slot_for(view, unretained_result(1, ["x"]))
    slot.source.should eq("fuzz·rebuilt")
    slot.summary.should contain("[fuzz·rebuilt]")
    slot.lines(:request).should_not be_empty
    slot.lines(:response).should be_empty
    slot.meta.status.should eq(404) # …and the row's own numbers survive
  end
end
