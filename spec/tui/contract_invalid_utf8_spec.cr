require "../support/tui_contract"
require "../support/overlay_harness"

include Gori::Tui

# CONTRACT: text that is not valid UTF-8 never takes the frame down.
#
# A captured method, host or path is wire bytes (`String.new(bytes)`, no scrub), and so is a
# saved stub body or an MCP client's self-reported name. PCRE2 raises `ArgumentError: Regex
# match error: UTF-8 error` on such a subject, and a raise on the RENDER path is the worst
# kind: the same frame is asked for again on the next tick, so it repeats until the tick
# breaker ends the session (`Runner#absorb_tick_error`). The 2026-08-15 crash audit found
# nine of these; this states the rule once for every controller, and pins the four sites a
# later review found still running a regex over untrusted text without a guard.
private def bad(prefix : String) : String
  String.new(prefix.to_slice + Bytes[0xff, 0xfe, 0x20, 0x41])
end

private def seed_invalid_flow(store : Gori::Store) : Int64
  method = bad("GET")
  host = bad("acme.test")
  target = bad("/p")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nX-Note: #{bad("v")}\r\n\r\n".to_slice,
    body: bad("{\"a\":1}").to_slice, content_type: "application/json"))
  id
end

describe "TUI contract — invalid UTF-8 never raises on the render path" do
  it "every controller renders and hints over a flow whose identity fields are wire bytes" do
    TuiContract.with_session("utf8-contract") do |session|
      seed_invalid_flow(session.store)
      failed = [] of String
      TuiContract.each_controller(session) do |controller, _host|
        controller.on_enter
        TuiContract.render(controller)
        controller.body_hint(:body)
      rescue ex
        failed << "#{controller.class}: #{ex.class}: #{ex.message}"
      end
      failed.should be_empty
    end
  end

  it "the agents chip strips controls from a client name that is not UTF-8" do
    # `scrub` marks the bad bytes as U+FFFD — a visible "something was here", which is the
    # right answer for a name shown on a chip; only the C0 control still gets stripped.
    AgentsOverlay.safe_client(bad("claude\u0001")).should eq("claude\uFFFD\uFFFD A")
  end

  it "the activity feed folds a message that is not UTF-8 onto one line" do
    ProjectView.act_one_line(bad("a\n\nb")).should_not contain("\n")
  end

  it "a hint template that is not UTF-8 is returned as written" do
    tpl = bad("{fuzz.run} run ")
    Gori::Hotkeys.expand(Gori::Verbs.registry, tpl).should eq(tpl)
  end

  it "the library picker draws a saved spec that is not UTF-8" do
    rows = [LibraryPicker::Row.new(0, "peel", bad("base64-decode\n> gunzip"))]
    h = OverlayHarness.new(LibraryPicker.new("LOAD CHAIN", rows, "chain"))
    h.render
    h.rendered?("peel").should be_true
  end
end
