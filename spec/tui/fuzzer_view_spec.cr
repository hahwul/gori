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

describe Gori::Tui::FuzzerView do
  it "CHAIN pane: focus a template marker, type a chain, commit writes it back" do
    view = FuzzerView.new
    # marker at offset 0 → set_text zeroes the cursor, so it sits inside §x§
    view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:template)
    view.chain_pane_active?.should be_false
    view.focus_chain_pane.should be_nil # in a marker → enters the pane
    view.chain_pane_active?.should be_true
    "rot13".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
    view.commit_chain_pane
    view.chain_pane_active?.should be_false
    view.template_text.should contain("§x¦rot13§")
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

    it "walks the single row cursor: sets → Add → Mode → Advanced → Run (clamped)" do
      view = loaded_fuzzer
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a"))
      view.focus_config
      view.config_row.should eq(:set)
      view.current_set_index.should eq(0)
      view.form_move(1); view.config_row.should eq(:add)
      view.form_move(1); view.config_row.should eq(:mode)
      view.form_move(1); view.config_row.should eq(:advanced)
      view.form_move(1); view.config_row.should eq(:run)
      view.form_move(1); view.config_row.should eq(:run) # clamped at the last row
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

    it "advanced_snapshot round-trips through apply_advanced" do
      view = loaded_fuzzer
      snap = view.advanced_snapshot
      edited = Gori::Tui::AdvancedSnapshot.new(
        conc: "50", rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        follow: true, calibrate: snap.calibrate,
        m_status: "200,500", m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex)
      view.apply_advanced(edited)
      back = view.advanced_snapshot
      back.conc.should eq("50")
      back.follow.should be_true
      back.m_status.should eq("200,500")
    end
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

    it "does not tint Replay/Notes editors (opt-in: bg_regions stays empty)" do
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

  it "hscroll_detail scrolls a long RESULT response line sideways into view (shift+←/→)" do
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
    backend.contains?("TAIL").should be_false # off the right edge, clipped

    20.times { view.hscroll_detail(1) } # scroll well past the line's width
    backend2 = MemoryBackend.new(80, 20)
    view.render(Screen.new(backend2), rect)
    backend2.contains?("TAIL").should be_true
    backend2.contains?("HEAD").should be_false # scrolled off the left edge
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
    view.template_text.split('\n')[1].should eq("Host: hX")
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
end
