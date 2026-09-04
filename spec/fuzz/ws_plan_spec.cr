require "../spec_helper"

private alias Fuzz = Gori::Fuzz

private HS = "GET /ws HTTP/1.1\r\nHost: w.test\r\n" \
             "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

# The RFC 8441 shape, as `H2::HeadCodec.synth_request` stores it: a `CONNECT` line plus the
# `X-Gori-Protocol` marker standing in for the `:protocol` pseudo-header (#733).
private CONNECT_HS = "CONNECT /ws HTTP/2\r\nHost: w.test\r\n" \
                     "Sec-WebSocket-Version: 13\r\nX-Gori-Protocol: websocket\r\n\r\n"

private PLAIN = "GET /api?q=§v§ HTTP/1.1\r\nHost: w.test\r\n\r\n"

private def build(template : String, ws : Array(Fuzz::WsMessageSource)? = nil,
                  config = Fuzz::Config.new, marks = [] of String,
                  auto = false, http2 = false) : Fuzz::Plan
  Fuzz::Plan.build(
    Fuzz::PlanOptions.new(template,
      default_target: "http://w.test",
      auto_mark: auto, marks: marks, http2: http2,
      sources: [Fuzz::InlineList.new(["a", "b"])] of Fuzz::PayloadSource,
      config: config, ws_messages: ws),
    ungated_outbound)
end

private def one_frame(text : String) : Array(Fuzz::WsMessageSource)
  [Fuzz::WsMessageSource.new(1, text)]
end

describe "Fuzz::Plan over a WebSocket script" do
  describe "genuine refusals (Fuzz::WsError)" do
    # Each of these is an incompatibility, not an inert flag — the inert ones are reported
    # through `ws_ignored_knobs` instead. `WsError < Gori::Error` rather than a new
    # `PlanError::Reason` member: that enum is `case … in`-exhausted by three surfaces, one of
    # which (the TUI Fuzzer tab) has no WebSocket path and could never produce this.
    it "refuses --race on a WebSocket script" do
      expect_raises(Fuzz::WsError, /race/) do
        build(HS, one_frame("§v§"), Fuzz::Config.new(race_count: 4))
      end
    end

    # …but only against an RFC 6455 `Upgrade:` handshake: HTTP/2 has no upgrade mechanism
    # (RFC 9113 §8.1), so there is nothing for the flag to send. An RFC 8441 extended CONNECT
    # is the h2 WebSocket and `http2` is true there by construction — see the example below.
    it "refuses http2 on an Upgrade-handshake script" do
      expect_raises(Fuzz::WsError, /no upgrade mechanism/) do
        build(HS, one_frame("§v§"), http2: true)
      end
    end

    it "accepts http2 on an RFC 8441 extended CONNECT script" do
      plan = build(CONNECT_HS, one_frame("§v§"), http2: true)
      plan.websocket?.should be_true
    end

    it "refuses frames given to a template with no handshake at all" do
      expect_raises(Fuzz::WsError, /no WebSocket handshake/) do
        build(PLAIN, one_frame("§v§"))
      end
    end
  end

  describe "inert knobs are reported, not refused" do
    it "names follow_redirects, timeout and auto_calibrate" do
      cfg = Fuzz::Config.new(follow_redirects: true, timeout: 5.seconds, auto_calibrate: true)
      plan = build(HS, one_frame("§v§"), cfg)
      plan.ws_ignored_knobs.should eq([:follow_redirects, :timeout, :auto_calibrate])
    end

    it "reports nothing when none was set" do
      build(HS, one_frame("§v§")).ws_ignored_knobs.should be_empty
    end

    it "reports nothing on an ordinary HTTP run, whatever was set" do
      cfg = Fuzz::Config.new(follow_redirects: true, timeout: 5.seconds, auto_calibrate: true)
      build(PLAIN, nil, cfg).ws_ignored_knobs.should be_empty
    end
  end

  describe "transport" do
    # One variation is one session on its own socket, which `WsEngine` closes in its own
    # `ensure` — there is nothing for the keep-alive pool to park. Forced off SILENTLY, because
    # `keep_alive` defaults true and the operator never chose it.
    it "forces the keep-alive pool off" do
      build(HS, one_frame("§v§"), Fuzz::Config.new(keep_alive: true)).pool.should be_nil
      build(PLAIN, nil, Fuzz::Config.new(keep_alive: true)).pool.should_not be_nil
    end

    # `Generator#calibration_requests` returns nothing on a WS script, and
    # `Engine#calibrate_baseline` returns early too: a sample is a FULL session, so calibrating
    # would perform the script's side effects before the sweep proper.
    it "produces no calibration requests" do
      build(HS, one_frame("§v§"), Fuzz::Config.new(auto_calibrate: true))
        .generator.calibration_requests(5).should be_empty
      build(PLAIN, nil, Fuzz::Config.new(auto_calibrate: true))
        .generator.calibration_requests(5).size.should eq(5)
    end
  end

  describe "positions across parts" do
    it "counts every part, while `template` stays the handshake alone" do
      hs = "GET /ws?room=§lobby§ HTTP/1.1\r\nHost: w.test\r\n" \
           "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      plan = build(hs, [Fuzz::WsMessageSource.new(1, "§a§"), Fuzz::WsMessageSource.new(1, "§b§")])
      plan.position_count.should eq(3)
      plan.template.position_count.should eq(1)
      plan.websocket?.should be_true
      plan.ws_script.not_nil!.frames.size.should eq(2)
    end

    it "refuses a script with no positions anywhere" do
      expect_raises(Fuzz::PlanError) { build(HS, one_frame("no markers here")) }
    end

    # A `--mark` aimed at a value that lives in a frame used to report `{token, 0}` and mark
    # nothing, while the operator watched the flag they typed do nothing to the payload they
    # typed it for.
    it "applies --mark across the frames, not just the handshake" do
      plan = build(HS, one_frame(%({"q":"NEEDLE","r":"NEEDLE"})), marks: ["NEEDLE"])
      plan.position_count.should eq(2)
      plan.mark_matches.should eq([{"NEEDLE", 2}])
    end

    # `--auto` marks a frame's VALUES by content sniff — a JSON scalar, an urlencoded pair —
    # because a frame has no request line and no Cookie header for the head half to read.
    it "auto-marks a JSON frame's scalars" do
      plan = build(HS, one_frame(%({"op":"sub","q":"term"})), auto: true)
      plan.position_count.should eq(2)
      plan.ws_script.not_nil!.default_payloads.should eq(["sub", "term"])
    end

    # …and leaves a payload it cannot read alone rather than guessing at it.
    it "leaves a non-JSON, non-urlencoded frame unmarked under --auto" do
      expect_raises(Fuzz::PlanError) { build(HS, one_frame("just some text"), auto: true) }
    end
  end

  describe "auto-encoding" do
    # A frame payload is not a URL: percent-encoding a `<` spliced into a JSON TEXT frame would
    # send a different test than the one that was marked. The handshake's query keeps it.
    it "encodes handshake query positions and no frame position" do
      hs = "GET /ws?room=§lobby§ HTTP/1.1\r\nHost: w.test\r\n" \
           "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      plan = build(hs, one_frame(%({"q":"§term§"})))
      plan.auto_encode.positions.to_a.should eq([0])
    end
  end

  describe "ws_http_only-shaped runs (no frames)" do
    it "sweeps an upgrade handshake as an ordinary HTTP request when no frames are given" do
      hs = "GET /ws?room=§lobby§ HTTP/1.1\r\nHost: w.test\r\n" \
           "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      plan = build(hs, nil)
      plan.websocket?.should be_false
      plan.ws_script.should be_nil
    end
  end
end
