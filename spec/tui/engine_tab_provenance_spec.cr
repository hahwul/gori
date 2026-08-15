require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"
require "socket"

# The four engine TUI tabs' PROVENANCE and REPORTING contracts.
#
# `Fuzz/Miner/Sequencer::PlanOptions#evidence?` existed and was passed by `gori run` at
# three call sites out of nine: the TUI Fuzzer/Miner/Sequencer views passed none of them.
# So a captured OData request (`?$filter=…&$top=10`) was REFUSED outright by all three
# tabs — zero requests sent — while `gori run fuzz --flow 1` swept it correctly, and once
# the operator followed the refusal's own advice and defined `filter`/`top`, every probe
# went out with its PARAMETER NAMES rewritten (`?PWNED=aa&99=10`) under a green
# `6 hits / 6 sent`. Builder-level coverage lives in spec/env_unresolved_spec.cr; what can
# only be checked HERE is that each view actually HANDS the builder its provenance.
#
# Every wire assertion reads the bytes a recording origin received, not the plan object:
# the whole class of defect here is a surface that assembles a plausible plan and then
# sends something else.
include Gori::Tui

private def with_vars(vars : Array({String, String}), &)
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = vars
  Gori::Settings.project_env_vars = [] of {String, String}
  yield
ensure
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
end

private def with_scope(&)
  path = File.tempname("gori-engine-tabs", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Scope.load(store)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A recording origin. Serves `reply` to every request and appends the EXACT head+body bytes
# it read to a shared array. `stop` closes the listener; the spec reads `requests` after
# the engine has finished, so there is no cross-fiber handshake to block on — the rule
# about a bare `Channel#receive` in a socket-driven spec is why this is an array and a
# server close rather than a rendezvous.
private class RecordingOrigin
  getter port : Int32
  getter requests = [] of String

  def initialize(@reply : String = "HTTP/1.1 200 OK\r\nSet-Cookie: SID=tok1; Path=/\r\nContent-Length: 2\r\n\r\nhi")
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @mutex = Mutex.new
    spawn(name: "rec-origin") { accept_loop }
  end

  def close : Nil
    @server.close rescue nil
  end

  # Request lines only — the common assertion, and the one the marker rewrites land in.
  def lines : Array(String)
    @mutex.synchronize { @requests.map { |r| r.lines.first? || "" } }
  end

  def bodies : Array(String)
    @mutex.synchronize do
      @requests.map { |r| (i = r.index("\r\n\r\n")) ? r[(i + 4)..] : "" }
    end
  end

  def heads : Array(String)
    @mutex.synchronize { @requests.map { |r| (i = r.index("\r\n\r\n")) ? r[0, i] : r } }
  end

  def count : Int32
    @mutex.synchronize { @requests.size }
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      spawn(name: "rec-conn") { serve(conn) }
    end
  rescue
    # listener closed — expected at teardown
  end

  private def serve(conn : TCPSocket) : Nil
    loop do
      head = read_head(conn)
      break unless head
      cl = content_length(head)
      body = cl > 0 ? read_exact(conn, cl) : ""
      @mutex.synchronize { @requests << "#{head}\r\n\r\n#{body}" }
      conn << @reply
      conn.flush
    end
  rescue
    # client closed / teardown
  ensure
    conn.close rescue nil
  end

  private def read_head(conn : TCPSocket) : String?
    buf = String::Builder.new
    seen = ""
    loop do
      b = conn.read_byte
      return nil unless b
      seen = "#{seen}#{b.unsafe_chr}"[-4..]? || seen + b.unsafe_chr
      buf << b.unsafe_chr
      break if seen == "\r\n\r\n"
    end
    s = buf.to_s
    s[0, s.size - 4]
  end

  private def read_exact(conn : TCPSocket, n : Int32) : String
    slice = Bytes.new(n)
    conn.read_fully(slice)
    String.new(slice)
  end

  private def content_length(head : String) : Int32
    head.each_line do |line|
      name, sep, value = line.partition(':')
      next if sep.empty?
      return value.strip.to_i? || 0 if name.strip.compare("content-length", case_insensitive: true) == 0
    end
    0
  end
end

private def flow_seeded_fuzzer(target : String, template : String) : FuzzerView
  view = FuzzerView.new
  # The ⇧I path assigns from a Store::FlowDetail; `restore` with a non-nil flow_id is the
  # same provenance through the persistence seam, and is what a reopened tab goes through.
  view.restore(Gori::Store::FuzzSessionRecord.new(
    id: 1, target: target, template: template, http2: false, sni: nil,
    config: "", flow_id: 7_i64, position: 0, name: nil))
  view
end

private def drafted_fuzzer(target : String, template : String) : FuzzerView
  view = FuzzerView.new
  view.load_request(target, template, false, "")
  view
end

private def run_fuzz(view : FuzzerView, scope : Gori::Scope) : String?
  engine, err = view.build_engine(false, scope, nil)
  return err unless engine
  engine.run { |_| }
  nil
end

describe "engine tabs — provenance (T1)" do
  it "the Fuzzer sends a CAPTURED head's own `$tokens` verbatim, and a DRAFT's expanded" do
    origin = RecordingOrigin.new
    begin
      with_vars([{"filter", "PWNED"}, {"top", "99"}]) do
        with_scope do |scope|
          tmpl = "GET /odata?$filter=§Price§&$top=10&id=7 HTTP/1.1\r\n" \
                 "Host: 127.0.0.1:#{origin.port}\r\nConnection: close\r\n\r\n"
          target = "http://127.0.0.1:#{origin.port}"

          view = flow_seeded_fuzzer(target, tmpl)
          view.evidence?.should be_true
          view.apply_set(nil, SetSpec.new(:list, "aa"))
          run_fuzz(view, scope).should be_nil

          # …and the complement, over the SAME bytes and the SAME vars: a template the
          # operator typed keeps the draft reading, where `$filter` IS a variable.
          draft = drafted_fuzzer(target, tmpl)
          draft.evidence?.should be_false
          draft.apply_set(nil, SetSpec.new(:list, "aa"))
          run_fuzz(draft, scope).should be_nil
        end
      end
      origin.lines.size.should eq(2)
      origin.lines[0].should eq("GET /odata?$filter=aa&$top=10&id=7 HTTP/1.1")
      origin.lines[1].should eq("GET /odata?PWNED=aa&99=10&id=7 HTTP/1.1")
    ensure
      origin.close
    end
  end

  it "the Fuzzer leaves a CAPTURED BODY's `$token` alone" do
    # A `$where` in a captured body used to be substituted with no refusal at all (the
    # refusal was head-only) and Content-Length silently resynced to the corrupted body
    # (37 → 39). Provenance is what closes it: on evidence the expansion does not run.
    origin = RecordingOrigin.new
    begin
      with_vars([{"where", "INJECTED"}]) do
        with_scope do |scope|
          body = %({"q":{"$where":"1==1"},"note":"ab"})
          tmpl = "POST /api/find?id=§3§ HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
                 "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}"
          view = flow_seeded_fuzzer("http://127.0.0.1:#{origin.port}", tmpl)
          view.apply_set(nil, SetSpec.new(:list, "ZZ"))
          run_fuzz(view, scope).should be_nil
        end
      end
      origin.bodies.size.should eq(1)
      origin.bodies[0].should contain(%("$where"))
      origin.bodies[0].should_not contain("INJECTED")
      origin.heads[0].should contain("Content-Length: 35") # the ORIGINAL body's length, unchanged
    ensure
      origin.close
    end
  end

  # INVERTED for the owner's round-7 policy. This used to assert that a CAPTURE with an
  # unset `$token` ran while a DRAFT carrying the same token was REFUSED — provenance
  # deciding which of the two the operator meant. The refusal is gone from both: an unset
  # `$NAME` is a literal string on the wire whatever its provenance, so `/odata?$filter=…`
  # builds either way. Provenance still decides EXPANSION, which the examples above pin.
  it "a capture AND a draft whose `$token` has no value both build" do
    with_vars([] of {String, String}) do
      with_scope do |scope|
        tmpl = "GET /odata?$filter=§Price§&$top=10 HTTP/1.1\r\nHost: t.test\r\n\r\n"
        seeded = flow_seeded_fuzzer("http://t.test", tmpl)
        seeded.apply_set(nil, SetSpec.new(:list, "aa"))
        engine, err = seeded.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil

        draft = drafted_fuzzer("http://t.test", tmpl)
        draft.apply_set(nil, SetSpec.new(:list, "aa"))
        engine, err = draft.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil
      end
    end
  end

  it "an EVIDENCE template still leaves the head CRLF-terminated after an editor edit" do
    # `evidence?` also switches OFF `expand_wire`'s LF→CRLF promotion, and `TextArea`
    # documents that promotion as what fixes up a line the user typed (`insert_newline`
    # gives it DEFAULT_EOL = "\n"). Without the view's own head normalization, adding one
    # header to a seeded capture would put a BARE LF in the head — a desync primitive, i.e.
    # a different test than the one on screen. The body stays byte-exact either way.
    origin = RecordingOrigin.new
    begin
      with_scope do |scope|
        tmpl = "GET /a?x=§1§ HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
               "X-Typed: fresh\nConnection: close\r\n\r\n"
        view = flow_seeded_fuzzer("http://127.0.0.1:#{origin.port}", tmpl)
        view.apply_set(nil, SetSpec.new(:list, "p"))
        run_fuzz(view, scope).should be_nil
      end
      origin.heads.size.should eq(1)
      origin.heads[0].should contain("\r\nX-Typed: fresh\r\n")
      origin.heads[0].should_not contain("fresh\nConnection")
    ensure
      origin.close
    end
  end

  it "the Miner hands the builder its seed's provenance (no editor exists to re-derive it)" do
    with_vars([] of {String, String}) do
      with_scope do |scope|
        req = "GET /odata?$filter=x&$top=10 HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice
        cfg = Gori::Miner::Config.new(locations: [Gori::Miner::Location::Query])

        seeded = MinerView.new
        seeded.load("http://t.test", req, false, nil, cfg, evidence: true)
        seeded.evidence?.should be_true
        engine, err = seeded.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil

        # The draft used to be REFUSED here for the same tokens; under the owner's round-7
        # policy it builds and ships them literally. What provenance still decides is
        # EXPANSION, so the flag itself is still asserted.
        draft = MinerView.new
        draft.load("http://t.test", req, false, nil,
          Gori::Miner::Config.new(locations: [Gori::Miner::Location::Query]))
        draft.evidence?.should be_false
        engine, err = draft.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil
      end
    end
  end

  it "the Sequencer hands the builder its seed's provenance" do
    with_vars([] of {String, String}) do
      with_scope do |scope|
        req = "GET /login?$filter=x HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice
        loc = Gori::Sequencer::TokenLoc.cookie("SID")

        seeded = SequencerView.new
        seeded.load("http://t.test", req, false, nil,
          Gori::Sequencer::Config.new(mode: Gori::Sequencer::Mode::LiveReplay, token_loc: loc, goal: 1),
          evidence: true)
        engine, err = seeded.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil

        # Same inversion as the Miner above: the draft builds now.
        draft = SequencerView.new
        draft.load("http://t.test", req, false, nil,
          Gori::Sequencer::Config.new(mode: Gori::Sequencer::Mode::LiveReplay, token_loc: loc, goal: 1))
        engine, err = draft.build_engine(false, scope, nil)
        err.should be_nil
        engine.should_not be_nil
      end
    end
  end

  it "provenance survives persistence, and a Repeater-sourced session never acquires it" do
    # `flow_id` is the carrier every one of the three session tables already had; nothing
    # but a flow seed ever sets it. Without this, a reopened capture silently reverted to a
    # draft on the next restart.
    rec = ->(flow_id : Int64?) do
      Gori::Store::FuzzSessionRecord.new(id: 1, target: "http://t.test",
        template: "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n", http2: false, sni: nil,
        config: "", flow_id: flow_id, position: 0, name: nil)
    end
    from_flow = FuzzerView.new
    from_flow.restore(rec.call(7_i64))
    from_flow.evidence?.should be_true
    from_flow.apply_peer_session(rec.call(7_i64))
    from_flow.evidence?.should be_true

    from_repeater = FuzzerView.new
    from_repeater.restore(rec.call(nil))
    from_repeater.evidence?.should be_false

    mrec = ->(flow_id : Int64?) do
      Gori::Store::MinerSessionRecord.new(id: 1, target: "http://t.test",
        request: Bytes.empty, http2: false, sni: nil, config: "",
        flow_id: flow_id, position: 0, name: nil)
    end
    m = MinerView.new
    m.restore(mrec.call(3_i64))
    m.evidence?.should be_true
    m.restore(mrec.call(nil))
    m.evidence?.should be_false

    srec = ->(flow_id : Int64?) do
      Gori::Store::SequencerSessionRecord.new(id: 1, target: "http://t.test",
        request: Bytes.empty, http2: false, sni: nil, config: "",
        flow_id: flow_id, position: 0, name: nil)
    end
    s = SequencerView.new
    s.restore(srec.call(3_i64))
    s.evidence?.should be_true
    s.restore(srec.call(nil))
    s.evidence?.should be_false
  end

  it "a duplicated fuzz session carries the same provenance as the bytes it copied" do
    src = flow_seeded_fuzzer("http://t.test", "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n")
    dup = FuzzerView.new
    dup.duplicate_from(src)
    dup.evidence?.should be_true

    draft = drafted_fuzzer("http://t.test", "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n")
    dup2 = FuzzerView.new
    dup2.duplicate_from(draft)
    dup2.evidence?.should be_false
  end
end

describe "Fuzzer tab — Content-Length (T2)" do
  it "sends the template's Content-Length as written once Auto Content-Length is off" do
    origin = RecordingOrigin.new
    begin
      with_scope do |scope|
        body = %({"q":"1==1"})
        tmpl = "POST /api?id=§3§ HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
               "Content-Length: 5\r\nConnection: close\r\n\r\n#{body}"

        on = drafted_fuzzer("http://127.0.0.1:#{origin.port}", tmpl)
        on.apply_set(nil, SetSpec.new(:list, "ZZ"))
        run_fuzz(on, scope).should be_nil
        on.rewrites_content_length?.should be_true # and it SAYS so, which is the half an
        #                                            operator who does not want the switch still needs

        off = drafted_fuzzer("http://127.0.0.1:#{origin.port}", tmpl)
        snap = off.advanced_snapshot
        off.apply_advanced(AdvancedSnapshot.new(
          conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
          max_requests: snap.max_requests, race: snap.race, follow: snap.follow, calibrate: snap.calibrate,
          keep_alive: snap.keep_alive, update_cl: false,
          m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
          f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex))
        off.apply_set(nil, SetSpec.new(:list, "ZZ"))
        run_fuzz(off, scope).should be_nil
        off.rewrites_content_length?.should be_false # the knob is off, so nothing is rewritten
      end
      origin.heads.size.should eq(2)
      origin.heads[0].should contain("Content-Length: #{%({"q":"1==1"}).bytesize}")
      origin.heads[1].should contain("Content-Length: 5")
    ensure
      origin.close
    end
  end

  it "retracts the CL claim when the template is edited, rather than leaving a stale one" do
    with_scope do |scope|
      tmpl = "POST /a?id=§3§ HTTP/1.1\r\nHost: t.test\r\nContent-Length: 5\r\n\r\nlonger-body"
      view = drafted_fuzzer("http://t.test", tmpl)
      view.apply_set(nil, SetSpec.new(:list, "ZZ"))
      view.build_engine(false, scope, nil)[0].should_not be_nil
      view.rewrites_content_length?.should be_true
      view.toggle_http2 # any edit to the buffer bumps TextArea#edits
      view.rewrites_content_length?.should be_false
    end
  end

  it "round-trips the toggle and the cap through the snapshot and through config JSON" do
    view = drafted_fuzzer("http://t.test", "GET /?x=1 HTTP/1.1\r\nHost: t.test\r\n\r\n")
    snap = view.advanced_snapshot
    snap.update_cl.should be_true # the ctor default, and the right one for an ordinary sweep
    snap.max_requests.should eq("")
    view.apply_advanced(AdvancedSnapshot.new(
      conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
      max_requests: "250", race: snap.race, follow: snap.follow, calibrate: snap.calibrate,
      keep_alive: snap.keep_alive, update_cl: false,
      m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
      f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex))
    view.advanced_snapshot.max_requests.should eq("250")
    view.config_json # the numeric buffers fold into @config at build/persist time
    view.config.max_requests.should eq(250_i64)
    view.config.update_content_length?.should be_false

    restored = FuzzerView.new
    restored.duplicate_from(view) # goes through config_json → apply_config_json
    restored.config.max_requests.should eq(250_i64)
    restored.config.update_content_length?.should be_false
    restored.advanced_snapshot.max_requests.should eq("250")

    # A session persisted BEFORE either key existed must keep the ctor defaults, not read
    # a missing key as "off" — the same nil-vs-false trap keep_alive already documents.
    old = FuzzerView.new
    old.restore(Gori::Store::FuzzSessionRecord.new(id: 1, target: "http://t.test",
      template: "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n", http2: false, sni: nil,
      config: %({"mode":"Sniper","concurrency":20}), flow_id: nil, position: 0, name: nil))
    old.config.update_content_length?.should be_true
    old.config.max_requests.should be_nil
  end
end

describe "Fuzzer tab — the requests it actually put on the wire (T3)" do
  it "shows `requests` only when retries/redirect hops made it exceed the payload count" do
    view = drafted_fuzzer("http://t.test", "GET /?x=§1§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
    view.begin_run(3_i64)
    3.times do |i|
      view.append_result(Gori::Fuzz::Result.new(i.to_i64, ["p#{i}"], nil, 200, 10_i64, 1, 1,
        100_i64, nil, false, false, nil))
    end
    view.finish_run

    # sent == requests: one number, not the same number twice.
    view.apply_progress(Gori::Fuzz::Progress.new(3_i64, 3_i64, 0_i64, 0_i64, requests: 3_i64))
    view.results_count_label.should eq("3 sent · 0 hit")

    # …and the case the tab used to hide entirely: 3 payloads, 18 requests at the origin.
    view.apply_progress(Gori::Fuzz::Progress.new(3_i64, 3_i64, 0_i64, 0_i64, requests: 18_i64))
    view.results_count_label.should eq("3 sent · 18 requests · 0 hit")
  end

  it "renders the wire count while the run is still streaming" do
    view = drafted_fuzzer("http://t.test", "GET /?x=§1§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
    view.begin_run(3_i64)
    view.apply_progress(Gori::Fuzz::Progress.new(1_i64, 3_i64, 0_i64, 0_i64, requests: 6_i64))
    view.results_count_label.should eq("running 1/3 · 6 req · 0 hit")
    view.apply_progress(Gori::Fuzz::Progress.new(1_i64, 3_i64, 0_i64, 0_i64, requests: 1_i64))
    view.results_count_label.should eq("running 1/3 · 0 hit")
  end
end

describe "Discover custom headers — a refusal, not a drop (T4)" do
  it "refuses to close on a line it will not send, and names it" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    h = OverlayHarness.new(ov)
    h.type("X Bad: value").should eq(:open) # a name with a space is not an RFC 7230 token
    ov.rejected_lines.should eq(["X Bad: value"])
    h.press(Termisu::Input::Key::Escape).should eq(:open) # esc must NOT save-and-close
    h.commits.should eq(0)
    h.rendered?("will not be sent").should be_true
    h.rendered?("X Bad").should be_true
  end

  it "closes once the line is fixed, and the refusal does not outlive it" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    h = OverlayHarness.new(ov)
    h.type("X Bad: value")
    h.press(Termisu::Input::Key::Escape).should eq(:open)
    6.times { h.press(Termisu::Input::Key::Backspace) } # "X Bad: value" → "X Bad:"
    h.rendered?("will not be sent").should be_false     # an edit retracts the standing refusal
    5.times { h.press(Termisu::Input::Key::Backspace) } # → "X"
    h.type("-Ok: fine")
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    ov.headers.should eq([{"X-Ok", "fine"}])
  end

  it "a click away is a refusal too — it is the same commit path" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    h = OverlayHarness.new(ov)
    h.type("X Bad: value")
    h.click(0, 0).should eq(:open)
    h.commits.should eq(0)
  end

  it "still accepts a clean header, and a blank line is not a rejection" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    h = OverlayHarness.new(ov)
    h.type("Authorization: Bearer $TOKEN")
    h.press(Termisu::Input::Key::Enter)
    h.press(Termisu::Input::Key::Enter) # a blank line in the buffer
    h.type("X-Ok: fine")
    ov.rejected_lines.should be_empty
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    ov.headers.should eq([{"Authorization", "Bearer $TOKEN"}, {"X-Ok", "fine"}])
  end
end

describe "engine tabs — budget (T5)" do
  it "every config overlay can cap a run, and starts uncapped" do
    mine = MineConfigOverlay.new(MineSeed.new(
      target: "http://t.test", request: "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice,
      http2: false, sni: nil, flow_id: nil, summary: "GET /",
      applicable: [Gori::Miner::Location::Query], default: [Gori::Miner::Location::Query]))
    mine.build_config.max_requests.should be_nil
    mine.set_selected(1) # max requests row
    mine.adjust(1)
    mine.build_config.max_requests.should eq(100_i64)

    seq = SequenceConfigOverlay.new(SequenceSeed.new(
      target: "http://t.test", request: "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice,
      http2: false, sni: nil, flow_id: nil, summary: "GET /",
      mode: Gori::Sequencer::Mode::LiveReplay,
      suggested_loc: Gori::Sequencer::TokenLoc.cookie("SID"),
      candidate_cookies: [] of String, candidate_headers: [] of String))
    seq.build_config.max_requests.should be_nil
    seq.set_selected(SequenceConfigOverlay::MAXREQ_ROW)
    seq.adjust(1)
    seq.build_config.max_requests.should eq(100_i64)

    disc = DiscoverConfigOverlay.new(DiscoverSeed.new(
      choices: [{"/", "http://t.test/"}], base_label: "t.test"))
    disc.build_config.max_requests.should be_nil
    disc.set_selected(DiscoverConfigOverlay::ROW_MAXREQ)
    disc.adjust(1)
    disc.build_config.max_requests.should eq(100_i64)
  end

  it "a mine that ran out of budget says so instead of `no hidden parameters found`" do
    view = MinerView.new
    view.load("http://t.test", "GET /?a=1 HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new(locations: [Gori::Miner::Location::Query], max_requests: 4_i64))
    view.begin_run
    view.apply_progress(Gori::Miner::Progress.new(434_i64, 0_i64, 4_i64, 0, 0_i64))
    view.budget_exhausted?.should be_false # still RUNNING — not a verdict yet
    view.finish_run
    view.budget_exhausted?.should be_true
    view.budget_note.should contain("434 of 434 names untested")

    # Complements: a COMPLETE run, and an uncapped run that was stopped by hand, must not
    # be relabelled as budget hits.
    done = MinerView.new
    done.load("http://t.test", "GET /?a=1 HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new(locations: [Gori::Miner::Location::Query], max_requests: 4_i64))
    done.begin_run
    done.apply_progress(Gori::Miner::Progress.new(434_i64, 434_i64, 9_i64, 0, 0_i64))
    done.finish_run
    done.budget_exhausted?.should be_false

    uncapped = MinerView.new
    uncapped.load("http://t.test", "GET /?a=1 HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new(locations: [Gori::Miner::Location::Query]))
    uncapped.begin_run
    uncapped.apply_progress(Gori::Miner::Progress.new(434_i64, 10_i64, 9_i64, 0, 0_i64))
    uncapped.finish_run
    uncapped.budget_exhausted?.should be_false
  end

  it "a collection that ran out of budget flags the sample its verdict rests on" do
    cfg = Gori::Sequencer::Config.new(mode: Gori::Sequencer::Mode::LiveReplay,
      token_loc: Gori::Sequencer::TokenLoc.cookie("SID"), goal: 500)
    cfg.max_requests = 50_i64
    view = SequencerView.new
    view.load("http://t.test", "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, nil, cfg)
    view.begin_run
    view.apply_progress(40, 50, 500, 0, 50_i64)
    view.budget_exhausted?.should be_false # running
    view.finish_run
    view.budget_exhausted?.should be_true
    view.budget_note.should contain("40 of 500 tokens")

    full = SequencerView.new
    full.load("http://t.test", "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice, false, nil, cfg)
    full.begin_run
    full.apply_progress(500, 500, 500, 0, 500_i64)
    full.finish_run
    full.budget_exhausted?.should be_false
  end

  it "a budget-halted crawl is its own state, never `done`" do
    run = DiscoverRun.new("http://t.test/", Gori::Discover::Config.new(max_requests: 8_i64))
    run.status = :done
    run.budget_exhausted?.should be_false
    run.status = :budget_exhausted
    run.budget_exhausted?.should be_true
    run.running?.should be_false

    # And the pane says what was NOT looked at rather than "no endpoints found".
    run.sent = 8_i64
    run.queued = 275
    screen = Screen.new(MemoryBackend.new(120, 24))
    run.status = :budget_exhausted
    view = DiscoverView.new
    view.add(run)
    backend = MemoryBackend.new(120, 24)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 24), true)
    backend.contains?("budget exhausted").should be_true
    backend.contains?("275").should be_true
    backend.contains?("no endpoints found").should be_false
    screen.should_not be_nil
  end
end
