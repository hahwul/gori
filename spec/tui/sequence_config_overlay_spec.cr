require "../spec_helper"

include Gori::Tui

private alias Q = Gori::Sequencer

private def seed(loc : Q::TokenLoc? = nil) : SequenceSeed
  SequenceSeed.new(
    target: "http://h.test",
    request: "GET /login HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
    http2: false, sni: nil, flow_id: nil, summary: "GET /login",
    mode: Q::Mode::LiveReplay, suggested_loc: loc,
    candidate_cookies: ["SID"], candidate_headers: ["x-csrf-token"])
end

# Rows: [0] kind, [1] selector, [2] samples, [3] max requests, [4] concurrency,
# [5] notify, [6] Start.
private def on_position_kind(text : String) : SequenceConfigOverlay
  ov = SequenceConfigOverlay.new(seed(Q::TokenLoc.new(Gori::ExtractKind::Position, "", 0, 0)))
  ov.set_selected(SequenceConfigOverlay::SELECTOR_ROW)
  ov.text_fields.first.set(text)
  ov
end

describe Gori::Tui::SequenceConfigOverlay do
  # RECONFIGURE (`c` on an open session) opens this same card, and Start writes the WHOLE
  # `Config` back — so every cycler the card does not carry over is a knob the reconfigure
  # RESETS. Only the descriptor was carried: a session set to 2000 samples / concurrency 5 /
  # a 5000-request cap / notify off came back as 500 / 1 / uncapped / when-done, silently,
  # from an operator who only wanted to fix a typo in the cookie name.
  describe "reconfiguring an open session" do
    it "opens on the session's own samples / max requests / concurrency / notify" do
      cfg = Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: Q::TokenLoc.cookie("SID"),
        goal: 2000, concurrency: 5)
      cfg.max_requests = 5000_i64
      cfg.notify = Q::NotifyMode::Off
      ov = SequenceConfigOverlay.new(SequenceSeed.new(
        target: "http://h.test", request: Bytes.empty, http2: false, sni: nil, flow_id: nil,
        summary: "GET /login", mode: Q::Mode::LiveReplay, suggested_loc: cfg.token_loc,
        candidate_cookies: [] of String, candidate_headers: [] of String, config: cfg))
      out = ov.build_config
      out.goal.should eq(2000)
      out.max_requests.should eq(5000_i64)
      out.concurrency.should eq(5)
      out.notify.should eq(Q::NotifyMode::Off)
      out.token_loc.selector.should eq("SID")
    end

    it "keeps 'uncapped' uncapped rather than snapping it to a budget" do
      cfg = Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: Q::TokenLoc.cookie("SID"))
      cfg.max_requests.should be_nil
      ov = SequenceConfigOverlay.new(SequenceSeed.new(
        target: "http://h.test", request: Bytes.empty, http2: false, sni: nil, flow_id: nil,
        summary: "GET /login", mode: Q::Mode::LiveReplay, suggested_loc: cfg.token_loc,
        candidate_cookies: [] of String, candidate_headers: [] of String, config: cfg))
      ov.build_config.max_requests.should be_nil
    end

    it "lands a value the cycler does not list on its nearest neighbour, visibly" do
      # A cycler can only offer what it lists. Snapping is what the operator READS on the card
      # before pressing Start; falling back to the default is what silently discards the
      # session's own setting.
      cfg = Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: Q::TokenLoc.cookie("SID"),
        goal: 1900, concurrency: 3)
      cfg.max_requests = 2600_i64
      ov = SequenceConfigOverlay.new(SequenceSeed.new(
        target: "http://h.test", request: Bytes.empty, http2: false, sni: nil, flow_id: nil,
        summary: "GET /login", mode: Q::Mode::LiveReplay, suggested_loc: cfg.token_loc,
        candidate_cookies: [] of String, candidate_headers: [] of String, config: cfg))
      out = ov.build_config
      out.goal.should eq(2000)
      out.max_requests.should eq(2500_i64)
      out.concurrency.should eq(2)
    end

    it "starts a NEW session on the defaults, with no config to carry" do
      ov = SequenceConfigOverlay.new(seed(Q::TokenLoc.cookie("SID")))
      out = ov.build_config
      out.goal.should eq(500)
      out.max_requests.should be_nil
      out.concurrency.should eq(1)
      out.notify.should eq(Q::NotifyMode::WhenDone)
    end
  end

  it "carries the seeded cookie descriptor into the config" do
    ov = SequenceConfigOverlay.new(seed(Q::TokenLoc.cookie("SID")))
    ov.valid?.should be_true
    cfg = ov.build_config
    cfg.mode.should eq(Q::Mode::LiveReplay)
    cfg.token_loc.kind.should eq(Gori::ExtractKind::Cookie)
    cfg.token_loc.selector.should eq("SID")
  end

  # The three surfaces must refuse the same descriptors. `--position 100` aborts on the CLI
  # and MCP's `position` raises, while this overlay parsed it as `a.to_i? || 0` — the range
  # `100:0`, which `TokenExtract.position` answers nil for on EVERY response. So Start ran a
  # real collection whose every sample missed and whose report read "0 usable · CRITICAL (no
  # usable tokens)": a verdict about the origin's entropy from a descriptor that never read a
  # byte of it.
  describe "a Position range the field does not spell" do
    it "refuses a range with no ':' separator" do
      on_position_kind("100").valid?.should be_false
    end

    it "refuses a non-numeric bound" do
      on_position_kind("a:b").valid?.should be_false
      on_position_kind("0:x").valid?.should be_false
    end

    it "refuses an empty or reversed range, which extracts nothing by construction" do
      on_position_kind("8:8").valid?.should be_false
      on_position_kind("40:8").valid?.should be_false
    end

    it "accepts a real range, spaces and all" do
      ov = on_position_kind(" 8 : 40 ")
      ov.valid?.should be_true
      loc = ov.build_config.token_loc
      loc.kind.should eq(Gori::ExtractKind::Position)
      loc.pos_start.should eq(8)
      loc.pos_end.should eq(40)
      loc.selector.should be_empty # Position reads the ints, never the selector string
    end

    # `commit_sequence` toasts this, and the Start row draws its short form: "set a token
    # location first" points at the row above the one that is actually wrong.
    it "names the range rather than the token location in its refusal" do
      on_position_kind("100").invalid_hint.should contain("A:B")
      SequenceConfigOverlay.new(seed(Q::TokenLoc.cookie(""))).invalid_hint
        .should eq("set a token location first")
    end
  end

  it "still refuses a blank selector for the selector-taking kinds" do
    ov = SequenceConfigOverlay.new(seed(Q::TokenLoc.new(Gori::ExtractKind::Regex, "")))
    ov.valid?.should be_false
    ov.set_selected(SequenceConfigOverlay::SELECTOR_ROW)
    ov.text_fields.first.set("SID=([a-f0-9]+)")
    ov.valid?.should be_true
  end
end
