require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def repeater_tmp_store(&)
  path = File.tempname("gori-rv", ".db")
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

describe Gori::Tui::RepeaterView do
  # These specs assert on RAW response rendering; keep the display-only pretty-printer
  # off so a (future) valid-JSON/XML fixture can't silently reflow and shift assertions.
  before_each { Gori::Settings.pretty_bodies_default = false }

  # The right-border scroll gauge: a heavy-vertical thumb rides the response card's
  # right edge ONLY when the body overflows the viewport, so its height reads as
  # "how big is this response" at a glance. A body that fits keeps the plain hairline.
  it "draws a right-border scroll gauge only when the response overflows the viewport" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)

    big = String.build do |io|
      io << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
      300.times { |i| io << "line #{i}\n" }
    end
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n".to_slice, big.to_slice, nil, 1000_i64))

    big_b = MemoryBackend.new(120, 20)
    view.render(Screen.new(big_b), Rect.new(0, 0, 120, 20))
    col = 119 # the response card's right border column (right half's right edge)
    thumb_rows = (0...20).count { |y| big_b.grid[y][col] == '┃' }
    thumb_rows.should be > 0  # a thumb segment is present
    thumb_rows.should be < 18 # but not the whole track — content clearly exceeds the pane

    # A tiny response fits the pane, so no gauge — the border stays a plain hairline.
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64))
    small_b = MemoryBackend.new(120, 20)
    view.render(Screen.new(small_b), Rect.new(0, 0, 120, 20))
    (0...20).count { |y| small_b.grid[y][col] == '┃' }.should eq(0)
  end

  # The response pane's ^X hex dump: repeater_toggle_hex routes response-focus to
  # exactly this view toggle (the `x` key selects a line now — hex moved to ^X).
  it "toggle_resp_hex flips resp_hex? and renders a raw byte dump of the response" do
    view = RepeaterView.new
    view.load_blank
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64))
    view.focus_pane(:response)
    view.resp_hex?.should be_false # plain response mode by default

    view.toggle_resp_hex
    view.resp_hex?.should be_true
    hexb = MemoryBackend.new(120, 20)
    view.render(Screen.new(hexb), Rect.new(0, 0, 120, 20))
    hexb.contains?("00000000").should be_true    # hex dump offset column
    hexb.contains?("50 4f 4e 47").should be_true # "PONG" as raw bytes

    view.toggle_resp_hex # ^X again exits back to the decoded body
    view.resp_hex?.should be_false
    plain = MemoryBackend.new(120, 20)
    view.render(Screen.new(plain), Rect.new(0, 0, 120, 20))
    plain.contains?("PONG").should be_true
  end

  it "load_blank seeds an editable, sendable scaffold (no source flow)" do
    view = RepeaterView.new
    view.load_blank
    view.loaded?.should be_true
    view.http2?.should be_false
    view.focus.should eq(:target) # new requests start on the target (you change the URL first)

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("https://example.com").should be_true # target field
    backend.contains?("GET / HTTP/1.1").should be_true      # scaffold request line
    backend.contains?("Host: example.com").should be_true   # scaffold header
    backend.contains?("— not sent — press ^R to resend —").should be_true
  end

  it "mirrors the target host into the Host header on the first edit of a blank tab" do
    view = RepeaterView.new
    view.load_blank
    view.request_text.should contain("Host: example.com") # the placeholder Host

    # Simulate replacing the target and leaving insert mode (the ^N → edit-target flow).
    view.enter_target_insert!
    view.target.size.times { view.target_backspace }
    "https://real.test".each_char { |c| view.target_insert(c) }
    view.exit_target_insert!

    view.target.should eq("https://real.test")
    view.request_text.should contain("Host: real.test")
    view.request_text.should_not contain("Host: example.com")
  end

  it "keeps a non-default port in the mirrored Host header" do
    view = RepeaterView.new
    view.load_blank
    view.enter_target_insert!
    view.target.size.times { view.target_backspace }
    "https://real.test:8443".each_char { |c| view.target_insert(c) }
    view.exit_target_insert!
    view.request_text.should contain("Host: real.test:8443")
  end

  it "syncs the Host only ONCE — a later target edit never re-clobbers it" do
    view = RepeaterView.new
    view.load_blank
    view.enter_target_insert!
    view.target.size.times { view.target_backspace }
    "https://real.test".each_char { |c| view.target_insert(c) }
    view.exit_target_insert! # first edit → Host synced to real.test

    # A second target change must NOT re-sync (so a hand-set Host survives).
    view.enter_target_insert!
    view.target.size.times { view.target_backspace }
    "https://other.test".each_char { |c| view.target_insert(c) }
    view.exit_target_insert!

    view.target.should eq("https://other.test")
    view.request_text.should contain("Host: real.test") # NOT re-synced to other.test
  end

  # ^R sends WITHOUT leaving target-insert (a modified chord defers past exit_target_insert!),
  # so repeater_send calls sync_host_to_target_once at send prep. Mimic that: type the target
  # but never exit insert, then run the send-time hook.
  it "mirrors the Host at send time even if the target edit never left insert mode" do
    view = RepeaterView.new
    view.load_blank
    view.enter_target_insert!
    view.target.size.times { view.target_backspace }
    "https://real.test".each_char { |c| view.target_insert(c) }
    view.sync_host_to_target_once # what repeater_send does beside commit_chain_pane (no exit_target_insert!)
    view.request_text.should contain("Host: real.test")
    view.request_text.should_not contain("Host: example.com")
  end

  # The clobber guard: leaving the target for the body must SPEND the one-shot, so a Host the
  # user then sets by hand (a deliberate Host≠target mismatch — Host-header attack) is never
  # overwritten by the send-time hook. This is why the primary trigger is focus-leave.
  it "never clobbers a hand-set Host once focus has left the target" do
    view = RepeaterView.new
    view.load_blank
    view.enter_target_insert!
    view.target.size.times { view.target_backspace }
    "https://real.test".each_char { |c| view.target_insert(c) }
    view.focus_pane(:request) # leaving the target flushes the link AND spends the one-shot
    view.request_text.should contain("Host: real.test")

    # User deliberately sets a mismatched Host in the body, then sends.
    view.replace_edit_buffer("GET / HTTP/1.1\nHost: evil.test\nUser-Agent: gori\n\n")
    view.sync_host_to_target_once # send-time hook — one-shot already spent, must be a no-op
    view.request_text.should contain("Host: evil.test")
    view.request_text.should_not contain("Host: real.test")
  end

  # The response body is styled one visible line at a time and memoized (per-line) so an
  # unrelated re-render (a keystroke in the request editor) doesn't re-tokenize the pane.
  # The memo must be dropped in lockstep with the response view — a new send, or a pretty
  # toggle — or a stale styled line would keep showing the OLD response.
  it "styled-line memo re-renders an unchanged response identically, but drops on a new send" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, %({"tag":"alpha"}).to_slice, nil, 1000_i64))

    first = MemoryBackend.new(120, 20)
    view.render(Screen.new(first), Rect.new(0, 0, 120, 20))
    first.contains?("alpha").should be_true

    # A second render with nothing changed is served from the memo — same output.
    again = MemoryBackend.new(120, 20)
    view.render(Screen.new(again), Rect.new(0, 0, 120, 20))
    again.contains?("alpha").should be_true

    # A new send must invalidate the memo: the pane shows the NEW body, not the cached one.
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, %({"tag":"bravo"}).to_slice, nil, 1000_i64))
    after = MemoryBackend.new(120, 20)
    view.render(Screen.new(after), Rect.new(0, 0, 120, 20))
    after.contains?("bravo").should be_true
    after.contains?("alpha").should be_false
  end

  # The memo reuses the SAME styled Line object across frames — safe only because every
  # downstream consumer (Highlight.draw / slice_chars / line_width_upto) is read-only.
  #
  # ASSERTION INVERTED BY SOFT WRAP. This used to prove the guard by scrolling the pane
  # sideways so `slice_left` ran on the cached Line and checking the head disappeared. The
  # response pane no longer scrolls sideways — a long body line WRAPS — so "head off the
  # left edge" is not a state the pane can reach, and `view.hscroll` is now a no-op stub.
  # What still needs guarding is the same thing: the per-row slicer (`Highlight.slice_chars`
  # now, driving the continuation rows) must not mutate the memoized Line. So the exercise
  # is the SLICE rather than the scroll — render a body wide enough to wrap (so every row
  # after the first is a slice of the cached Line), scroll DOWN through it and back, and
  # require the first row to be intact. A slicer that mutated in place would have eaten the
  # head exactly as before.
  it "styled-line memo survives a wrap-slice round-trip without corrupting the cached line" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
    body = %({"a":"ALPHATOKEN#{"_" * 90}OMEGATOKEN"})
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, body.to_slice, nil, 1000_i64))

    at0 = MemoryBackend.new(50, 12)
    view.render(Screen.new(at0), Rect.new(0, 0, 50, 12))
    at0.contains?("ALPHATOKEN").should be_true  # first row of the body, memo populated
    at0.contains?("OMEGATOKEN").should be_false # its tail is further down, on a later row

    view.scroll(6) # drop the head off the TOP → the visible rows are all slices of the memo
    scrolled = MemoryBackend.new(50, 12)
    view.render(Screen.new(scrolled), Rect.new(0, 0, 50, 12))
    scrolled.contains?("ALPHATOKEN").should be_false
    scrolled.contains?("OMEGATOKEN").should be_true # the tail IS reachable — by wrapping, not by panning

    view.scroll(-6) # back to the top
    back = MemoryBackend.new(50, 12)
    view.render(Screen.new(back), Rect.new(0, 0, 50, 12))
    back.contains?("ALPHATOKEN").should be_true # cached Line uncorrupted by the intervening slices
  end

  # Reveal mode is the surface built to inspect whitespace, and it was the one surface a
  # tabbed line could not be scrolled across. Reveal.styled gives every control char a
  # 1-column marker (tab → '→'), so the row DRAWS one cell per tab, but the h-scroll clamp
  # measured the raw string with display_width, where a tab is 0 columns. On a tab-heavy
  # line the clamp's ceiling collapsed to 0 and the offset was pinned there every frame, so
  # the tail of the line was permanently unreachable no matter how far right you scrolled.
  #
  # ASSERTION INVERTED BY SOFT WRAP. The bug's root cause — a width measure that scores a
  # tab 0 while the draw gives it a cell — is unchanged and still the thing under test, but
  # it now shows up in the WRAP rather than in a scroll ceiling: `Wrap` must break this line
  # on `grapheme_cols` (tab = 1), so the 74 drawn columns land on two rows and the tail is
  # visible WITHOUT scrolling at all. Measured under display_width the line is 14 columns,
  # would not wrap, and ENDTOK would be off the right edge again — so the assertion flips
  # from "invisible until scrolled" to "visible on the continuation row", and the old
  # failure mode is still caught.
  it "wraps a tab-filled line by its DRAWN width in reveal mode, tail and all" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
    line = "STARTTOK#{"\t" * 60}ENDTOK"
    # The two measures disagree by the tab count — that gap IS the tail that used to vanish.
    Screen.display_width(line).should eq(14)
    Screen.draw_width(line).should eq(74)
    view.apply(Gori::Repeater::Result.new(hdr.to_slice, line.to_slice, nil, 1000_i64))
    view.reveal = true

    at0 = MemoryBackend.new(60, 20)
    view.render(Screen.new(at0), Rect.new(0, 0, 60, 20))
    at0.contains?("STARTTOK").should be_true # first row of the line
    at0.contains?("ENDTOK").should be_true   # …and its tail, on a continuation row
    at0.contains?("→").should be_true        # reveal really is drawing tab markers
  end

  it "duplicate_from copies request content, flags, and last response (no source flow)" do
    src = RepeaterView.new
    src.load_blank
    src.name = "alpha"
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    src.apply(ok)

    dst = RepeaterView.new
    dst.duplicate_from(src)
    dst.loaded?.should be_true
    dst.target.should eq(src.target)
    dst.request_text.should eq(src.request_text)
    dst.name.should eq("alpha copy")
    dst.source_flow_id.should be_nil
    dst.dirty?.should be_true

    backend = MemoryBackend.new(120, 20)
    dst.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
  end

  it "stays in plain response mode after sending a blank (nothing to diff against)" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus.should eq(:target) # send keeps the current focus (was :target from load_blank)

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
    # plain response mode: the diff toggle chip is inactive (muted), not lit — the
    # pane no longer carries a separate "response" chip (it's titled RESPONSE).
    ry = (0...20).find { |y| backend.row(y).includes?("d:diff") }.not_nil!
    dx = backend.row(ry).index("diff").not_nil!
    backend.fg_at(dx, ry).should eq(Theme.muted) # diff segment inactive
  end

  it "explains there is nothing to diff when a blank's response pane is toggled to diff" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.toggle_resp_mode # response → diff

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("first send").should be_true # no previous response to diff against yet
    backend.contains?("+ PONG").should be_false    # not shown as a spurious addition
  end

  it "diffs the latest response against the PREVIOUS send (not just the original)" do
    view = RepeaterView.new
    view.load_blank
    first = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "ONE".to_slice, nil, 1000_i64)
    view.apply(first) # first send: nothing to diff against yet → response mode
    view.focus.should eq(:target)
    view.toggle_resp_mode # user opens the diff tab

    second = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "TWO".to_slice, nil, 1000_i64)
    view.apply(second) # second send keeps the diff tab (last-open) → diffs vs the first send

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("- ONE").should be_true # previous response body removed
    backend.contains?("+ TWO").should be_true # current response body added
  end

  it "keeps the last-open response tab on send (does not auto-jump to diff)" do
    repeater_tmp_store do |store|
      # A History-loaded flow is diffable from the very first send (baseline = the
      # captured original), which used to force the diff tab open on send.
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: Bytes.empty))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ORIG".to_slice))
      view = RepeaterView.new
      view.load(store.get_flow(id).not_nil!)

      ok = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "NEW".to_slice, nil, 1000_i64)
      view.apply(ok) # send: must stay on response (the last-open tab), not jump to diff

      backend = MemoryBackend.new(120, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
      backend.contains?("NEW").should be_true
      # response view kept — the diff toggle was NOT auto-opened (muted, inactive)
      ry = (0...20).find { |y| backend.row(y).includes?("d:diff") }.not_nil!
      dx = backend.row(ry).index("diff").not_nil!
      backend.fg_at(dx, ry).should eq(Theme.muted) # diff tab NOT auto-opened
    end
  end

  it "drops back to response when an errored send can't render the held diff tab" do
    view = RepeaterView.new
    view.load_blank
    first = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "ONE".to_slice, nil, 1000_i64)
    view.apply(first)
    view.toggle_resp_mode # open the diff tab
    err = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
    view.apply(err) # errored send: fall back so the error is visible in the response view

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("repeater error: connection refused").should be_true
    # fell back to the response view — the diff toggle is inactive (muted)
    ry = (0...20).find { |y| backend.row(y).includes?("d:diff") }.not_nil!
    dx = backend.row(ry).index("diff").not_nil!
    backend.fg_at(dx, ry).should eq(Theme.muted)
  end

  it "auto-updates an existing Content-Length to match the edited body on send" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/x", http_version: "HTTP/1.1",
        head: "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 99\r\n\r\n".to_slice,
        body: "hello".to_slice)) # stale CL=99, real body is 5 bytes
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      detail = store.get_flow(id).not_nil!

      view = RepeaterView.new
      view.load(detail)
      view.auto_content_length?.should be_true                        # default on
      view.request_text.includes?("Content-Length: 5").should be_true # reflected in the editor too
      sent = String.new(view.request_bytes)
      sent.includes?("Content-Length: 5").should be_true   # recomputed to the body size
      sent.includes?("Content-Length: 99").should be_false # stale value replaced

      view.toggle_auto_content_length # off → send byte-exact (the already-synced editor)
      String.new(view.request_bytes).includes?("Content-Length: 5").should be_true

      byte_exact = RepeaterView.new
      byte_exact.restore("https://h.test",
        "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhello", false, false)
      String.new(byte_exact.request_bytes).includes?("Content-Length: 99").should be_true
    end
  end

  # Regression for the "Repeater silently corrupts binary/non-UTF-8 request bodies on
  # every default-path send" bug: a History-loaded flow whose body has genuinely
  # invalid UTF-8 (a lone continuation byte, a truncated multi-byte lead — NOT just an
  # embedded NUL, which is valid single-byte UTF-8) used to come out of `request_bytes`
  # with those bytes rewritten to U+FFFD by `Env.expand`'s old `String#chars` rebuild,
  # even though the request has no `$KEY` token anywhere — silently changing the
  # Content-Length and garbling the body on a plain ^R send.
  it "resends an invalid-UTF-8 body byte-exact via the default (no $KEY) send path" do
    repeater_tmp_store do |store|
      body = Bytes[0x41, 0x80, 0x42, 0xE2, 0x28, 0x43] # 6 bytes; 0x80 and 0xE2,0x28 are invalid UTF-8
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/x", http_version: "HTTP/1.1",
        head: "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 6\r\n\r\n".to_slice,
        body: body))
      detail = store.get_flow(id).not_nil!

      view = RepeaterView.new
      view.load(detail)

      sent = view.request_bytes
      String.new(sent).includes?("Content-Length: 6").should be_true # size did NOT balloon (was corrupted to a larger CL)
      sent[-body.size, body.size].should eq(body)                    # body bytes preserved exactly
    end
  end

  # Same corruption class, but with a `$KEY` token present elsewhere in the request.
  #
  # The substitution half MOVED, and this example was pinning the wrong half of it. A tab
  # loaded from `load(detail)` holds a CAPTURED request, and a capture is replayed as
  # recorded — `$TOKEN` in a stored head is a byte the client really sent, and every other
  # surface already knew it (`gori run repeater <flow-id>` and MCP `send_request{flow_id}`
  # both send those seven characters). The TUI was the one surface still substituting, so
  # the SAME flow id in the SAME project produced two different requests. See
  # `RepeaterView#evidence?` and `Repeater::PlanOptions#evidence?`.
  #
  # What the example is actually about — an invalid-UTF-8 body surviving the send path
  # whatever else happens to the head — is asserted on BOTH sides of that split.
  it "leaves a CAPTURED $KEY alone, and an invalid-UTF-8 body untouched either way" do
    Gori::Settings.env_vars = [{"TOKEN", "secret"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    repeater_tmp_store do |store|
      body = Bytes[0x41, 0x80, 0x42, 0xE2, 0x28, 0x43]
      head = "POST /x HTTP/1.1\r\nHost: h.test\r\nAuthorization: $TOKEN\r\nContent-Length: 6\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/x", http_version: "HTTP/1.1",
        head: head.to_slice, body: body))
      detail = store.get_flow(id).not_nil!

      view = RepeaterView.new
      view.load(detail)

      sent = view.request_bytes
      String.new(sent).includes?("Authorization: $TOKEN").should be_true # evidence: byte-exact
      String.new(sent).includes?("Authorization: secret").should be_false
      sent[-body.size, body.size].should eq(body) # body bytes still preserved exactly

      # THE COMPLEMENT: the identical bytes typed as a DRAFT still substitute, and the body
      # still survives. Provenance is the only thing that differs between the two.
      draft = RepeaterView.new
      draft.restore("http://h.test", head, false, false)
      draft.replace_request(head + String.new(body))
      draft_sent = draft.request_bytes
      String.new(draft_sent).includes?("Authorization: secret").should be_true
      draft_sent[-body.size, body.size].should eq(body)
    end
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end

  # The complement of the spec above, and the half that was missing: evidence used to switch
  # `$KEY` substitution off for the whole TAB, so an `Authorization: $TOKEN` the OPERATOR
  # typed into a ^R-from-History tab went to the origin as six literal bytes — while the
  # editor's own value peek showed the resolved secret under the caret. Provenance is per
  # NAME: a name the capture never mentioned cannot be an origin byte.
  it "substitutes a $KEY the operator typed into an evidence tab, keeping the capture's own literal" do
    Gori::Settings.env_vars = [{"TOKEN", "secret"}, {"filter", "PWNED"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    repeater_tmp_store do |store|
      head = "GET /api?$filter=name HTTP/1.1\r\nHost: h.test\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/api?$filter=name", http_version: "HTTP/1.1",
        head: head.to_slice, body: nil))
      view = RepeaterView.new
      view.load(store.get_flow(id).not_nil!)

      # The operator adds a header referencing a name the CAPTURE never carried.
      view.replace_request("GET /api?$filter=name HTTP/1.1\r\nHost: h.test\r\nAuthorization: $TOKEN\r\n\r\n")
      sent = String.new(view.request_bytes)
      sent.includes?("Authorization: secret").should be_true # theirs → expanded
      sent.includes?("$filter=name").should be_true          # the capture's → still literal
      sent.includes?("PWNED").should be_false
    end
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end

  # Display has to agree with the wire, or the peek/colour is a promise the send breaks.
  it "marks the capture's own $KEYs literal for the editor's peek and colouring" do
    Gori::Settings.env_vars = [{"TOKEN", "secret"}, {"filter", "PWNED"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    repeater_tmp_store do |store|
      head = "GET /api?$filter=name HTTP/1.1\r\nHost: h.test\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/api?$filter=name", http_version: "HTTP/1.1",
        head: head.to_slice, body: nil))
      view = RepeaterView.new
      view.load(store.get_flow(id).not_nil!)

      literal = Gori::Tui::Highlight.from_lines(["GET /api?$filter=x HTTP/1.1"], true, literal: Set{"filter"})
      known = Gori::Tui::Highlight.from_lines(["GET /api?$filter=x HTTP/1.1"], true)
      tok = literal[0].find { |s| s.text == "$filter" }.not_nil!
      tok.fg.should eq(Gori::Tui::Theme.env_unknown)
      known[0].find { |s| s.text == "$filter" }.not_nil!.fg.should eq(Gori::Tui::Theme.env_known)
    end
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end

  # A pasted request is spliced in as ONE edit; the marker guard is the one thing that sends
  # it back to the keystroke path, because `edit_insert` escapes a `§`/`¦` that would nest
  # inside a closed marker and a bulk splice cannot ask that per character.
  describe "#edit_paste (bulk bracketed paste)" do
    it "splices a whole pasted request in as one edit and reflects Content-Length once" do
      view = RepeaterView.new
      view.load_blank
      view.focus_pane(:request)
      view.enter_request_insert!
      view.edit_paste("POST /a HTTP/1.1\nHost: h.test\nContent-Length: 4\n\nbody").should be_true
      view.request_text.should contain("POST /a HTTP/1.1")
      view.request_text.should contain("body")
      view.dirty?.should be_true
    end

    it "refuses a clipboard carrying a § so the per-character marker guard still runs" do
      view = RepeaterView.new
      view.load_blank
      view.focus_pane(:request)
      view.enter_request_insert!
      view.edit_paste("q=§payload§").should be_false
      view.request_text.should_not contain("§") # nothing was inserted — the Runner replays it
    end

    it "refuses when the request pane is not an open text editor" do
      view = RepeaterView.new
      view.load_blank
      view.focus_pane(:request) # READ mode — no caret to paste at
      view.edit_paste("x").should be_false
    end
  end

  it "reflects auto Content-Length in the visible REQUEST editor (^L on)" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhello", false, false)
    view.request_text.includes?("Content-Length: 99").should be_true

    view.toggle_auto_content_length # on → resync into the editor
    view.request_text.includes?("Content-Length: 5").should be_true
    view.request_text.includes?("Content-Length: 99").should be_false
  end

  it "reflects the RENDERED Content-Length when a §…§ marker + auto-CL are both on" do
    view = RepeaterView.new
    # auto-CL (^L) on; §…§ markers are always active (no mode). Body q=§hi§ is 8 raw bytes
    # but renders to q=hi (4 bytes) — the value ^R actually sends.
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\nContent-Length: 0\n\nq=§hi§", false, true)
    String.new(view.request_bytes).includes?("Content-Length: 4").should be_true # what ^R sends
    view.request_text.includes?("Content-Length: 4").should be_true              # editor matches (was 8)
    view.request_text.includes?("Content-Length: 8").should be_false
  end

  # The reflection replaces the WHOLE Content-Length line, and it runs on every keystroke —
  # so the transient line a paste (or a typed header) makes, with the buffer's next line still
  # glued to its tail, used to be swallowed by the rewrite. Typing `Content-Length: 5` in front
  # of `User-Agent: gori` destroyed the User-Agent, silently and unrecoverably (see the undo
  # spec below). A value that is not a bare number means "mid-edit or deliberate" — leave it.
  it "does not rewrite a Content-Length line whose value is not a plain number" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nUser-Agent: gori\n\nhi", false, true)
    view.pane_advance(1) # :target → :request
    view.goto_request_line(3)
    "Content-Length: 5".each_char { |c| view.edit_insert(c) }

    # Every character typed survives, and so does the line it was typed in front of.
    view.request_text.includes?("Content-Length: 5User-Agent: gori").should be_true
    view.request_text.includes?("User-Agent: gori").should be_true
  end

  # A `Content-Length: 0abc` / `+5` / `5 ` is a smuggling or desync primitive an operator types
  # ON PURPOSE. Auto-CL's job is keeping an ordinary length honest while the body is edited,
  # not correcting a deliberately malformed one — the test on screen must be the test on the
  # wire (P7).
  it "leaves a deliberately malformed Content-Length value alone" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 0abc\n\nhi", false, true)
    view.pane_advance(1)
    view.goto_request_line(5) # body line
    view.edit_insert('!')
    view.request_text.includes?("Content-Length: 0abc").should be_true
  end

  # The reflection is itself an edit, so running it on the state ⌃Z just restored re-applies
  # the change being undone: an auto-CL rewrite was unreachable by undo at any depth.
  it "⌃Z restores a line the auto-Content-Length reflection rewrote" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhi", false, true)
    view.pane_advance(1)
    view.goto_request_line(5)
    view.request_text.includes?("Content-Length: 2").should be_true # restore already reflected
    view.edit_insert('!')
    view.request_text.includes?("Content-Length: 3").should be_true # …and so did the keystroke

    view.edit_undo # the reflection…
    view.edit_undo # …then the keystroke
    view.request_text.includes?("Content-Length: 2").should be_true
    view.request_text.includes?("hi!").should be_false
  end

  it "keeps the REQUEST editor's Content-Length in sync while editing the body" do
    view = RepeaterView.new
    view.restore("https://h.test",
      "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nhi", false, true)
    view.pane_advance(1)      # :target → :request
    view.goto_request_line(5) # body line
    view.edit_insert('!')
    view.request_text.includes?("Content-Length: 3").should be_true # body "hi!" is 3 bytes
    view.request_text.includes?("Content-Length: 99").should be_false
  end

  # Reconcile fires on every capture-driven data_version tick, and set_text zeroes the caret +
  # scroll and clears undo — so a compare that is falsely unequal slams the request caret to
  # the top of the pane on every tick (only visible in READ mode; INS locks the tab out of
  # reconcile). The compare used to normalize CRLF→LF because the editor could only HOLD LF;
  # now `request_text` is wire form (TextArea#wire_text, set_text's exact inverse) and the
  # store row is written from it, so a CRLF-stored request seeded into a CRLF editor is equal
  # on the nose — which is the path that actually ticks (^R from History, MCP create_repeater,
  # import: all wire CRLF).
  it "request_side_matches? is exact on the wire form the store round-trips" do
    view = RepeaterView.new
    crlf_row = "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n"
    view.restore("https://h.test", crlf_row, false, false)
    view.request_text.should eq(crlf_row) # the editor gives the row back byte for byte
    view.request_side_matches?("https://h.test", crlf_row, false, false, nil).should be_true

    # An LF-stored row seeded into an LF editor is equally exact (a pre-fix DB, or MCP writing
    # LF) — the point is that the editor no longer flattens what it was given.
    lf = RepeaterView.new
    lf.restore("https://h.test", "GET /a HTTP/1.1\nHost: h.test\n\n", false, false)
    lf.request_side_matches?("https://h.test", "GET /a HTTP/1.1\nHost: h.test\n\n",
      false, false, nil).should be_true
  end

  # The flip side of exactness, and a deliberate behaviour change: a peer that rewrote ONLY
  # the line endings changed the bytes gori will put on the wire, so reconcile must NOT skip.
  # It re-applies once and then matches (the editor now holds the peer's endings), so this
  # converges — it does not re-slam the caret every tick.
  it "request_side_matches? treats a line-ending-only difference as a real change" do
    view = RepeaterView.new
    view.restore("https://h.test", "GET /a HTTP/1.1\nHost: h.test\n\n", false, false)
    crlf_row = "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n"
    view.request_side_matches?("https://h.test", crlf_row, false, false, nil).should be_false
    view.apply_peer_request("https://h.test", crlf_row, false, false)
    view.request_side_matches?("https://h.test", crlf_row, false, false, nil).should be_true
  end

  # A soft reconcile sync that only touched a non-text field (here: the http2 flag) must not
  # rewrite the editor — set_text zeroes the caret + scroll and clears undo. Guarded like
  # FuzzerView#apply_peer_session / NotesView#soft_merge_from.
  it "apply_peer_request keeps the request caret when only a non-text field changed" do
    view = RepeaterView.new
    req = "GET /aaa HTTP/1.1\r\nHost: h.test\r\nX-A: 1\r\nX-B: 2\r\n\r\n"
    view.restore("https://h.test", req, false, false)
    view.pane_advance(1)      # :target → :request
    view.goto_request_line(3) # caret at "X-A: 1", col 0
    # Same request, only http2 flipped → text unchanged → set_text skipped.
    view.apply_peer_request("https://h.test", req, true, false)
    view.edit_insert('Z')
    view.request_text.includes?("ZX-A: 1").should be_true # caret preserved mid-buffer
    view.request_text.includes?("ZGET").should be_false   # NOT reset to the top
  end

  it "sends a lone § (no complete §…§ region) verbatim — byte-identical to today" do
    view = RepeaterView.new
    # a single § doesn't form a §…§ region, so there's nothing to render — sent as typed.
    view.restore("https://a.test", "POST /x HTTP/1.1\nHost: a.test\n\nq=§hi", false, false)
    String.new(view.request_bytes).should eq("POST /x HTTP/1.1\r\nHost: a.test\r\n\r\nq=§hi")
  end

  it "does not double CRLF when a $KEY value carries its own CRLF" do
    # A var value with an embedded CRLF must land in the wire request as a single CRLF,
    # not `\r\r\n` — parity with Env.expand_wire (the CLI/MCP send path). The old
    # split('\n').join("\r\n") over already-expanded text doubled it, corrupting the line.
    prev = Gori::Settings.env_vars
    begin
      Gori::Settings.env_vars = [{"MULTI", "a\r\nb"}]
      view = RepeaterView.new
      view.restore("https://h.test", "POST /x HTTP/1.1\nHost: h.test\n\n$MULTI", false, false)
      sent = String.new(view.request_bytes)
      sent.should eq("POST /x HTTP/1.1\r\nHost: h.test\r\n\r\na\r\nb")
      sent.includes?("\r\r\n").should be_false
    ensure
      Gori::Settings.env_vars = prev
    end
  end

  it "applies a §…§ marker's inline chain on send + resyncs Content-Length" do
    view = RepeaterView.new
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\nContent-Length: 99\n\ntok=§secret¦base64-encode§", false, true)
    sent = String.new(view.request_bytes)
    sent.includes?("tok=c2VjcmV0").should be_true       # base64("secret") == c2VjcmV0
    sent.includes?("Content-Length: 12").should be_true # body "tok=c2VjcmV0" is 12 bytes
    sent.includes?("Content-Length: 99").should be_false
  end

  # A §…§ marker whose `¦chain` cannot run must REFUSE the send with a named ChainError
  # (mirroring Fuzz::Plan#refuse_unusable_chains) — never drop the raw, untransformed value
  # onto the wire. See RepeaterView#refuse_bad_chains.
  it "refuses a §…§ send whose ¦chain names a MISSING converter (no bytes on the wire)" do
    view = RepeaterView.new
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\n\ntok=§secret¦nosuchconv§", false, true)
    ex = expect_raises(Gori::Fuzz::ChainError, /nosuchconv/) do
      view.request_bytes
    end
    ex.message.not_nil!.should contain("unknown converter")
    ex.message.not_nil!.should contain("would go out untransformed")
  end

  it "refuses a §…§ send whose ¦chain FAILS on its value (hex-decode over non-hex)" do
    view = RepeaterView.new
    # hex-decode over "secret" raises (non-hex chars) — the marked default is the one value
    # going out, so unlike a Fuzz sweep there is no next payload; the raw value must not ship.
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\n\ntok=§secret¦hex-decode§", false, true)
    expect_raises(Gori::Fuzz::ChainError, /hex-decode/) do
      view.request_bytes
    end
  end

  it "sends byte-exact when a §…§ ¦chain is VALID (the complement — must not over-refuse)" do
    view = RepeaterView.new
    view.restore("https://a.test",
      "POST /x HTTP/1.1\nHost: a.test\n\ntok=§secret¦base64-encode§", false, true)
    String.new(view.request_bytes).should contain("tok=c2VjcmV0") # runs, no refusal
  end

  it "leaves a request with NO §…§ marker unaffected by the chain refusal" do
    view = RepeaterView.new
    view.restore("https://a.test", "POST /x HTTP/1.1\nHost: a.test\n\nq=hi", false, false)
    String.new(view.request_bytes).should eq("POST /x HTTP/1.1\r\nHost: a.test\r\n\r\nq=hi")
  end

  # PROVENANCE: `§` (U+00A7) is ordinary text — a German/legal body carries it constantly —
  # so a `§…§` pair that arrived as CAPTURED evidence is data, not the operator's marker
  # syntax. The Repeater used to parse it as a template anyway: both § were deleted from the
  # wire and `Content-Length` was re-synced behind the loss, while `gori run repeater <id>`
  # and MCP `send_request{flow_id}` replayed the same flow byte-exact. See
  # `RepeaterView#markers_live?`.
  describe "§ in a CAPTURED body is data, not marker syntax" do
    # The hunter's vector: `§` next to every other byte class that already survives a send —
    # a CRLF in the body, invalid UTF-8, a captured `$TOKEN`, a tab — so a failure here can
    # only be the marker path.
    body = IO::Memory.new.tap { |io|
      io << %({"note":"a\r\nb","mk":"§SEED§","env":"$TOKEN","bin":")
      io.write(Bytes[0xFF, 0xFE, 0x01, 0x02])
      io << %(","tab":"\tx"})
    }.to_slice
    head = "POST /seed?q=1&r=2 HTTP/1.1\r\nHost: h.test\r\n" \
           "Content-Type: application/json\r\nContent-Length: #{body.size}\r\n" \
           "Connection: close\r\n\r\n"
    wire = head + String.new(body)

    # `§SEED§` as it sits on the wire: c2 a7 53 45 45 44 c2 a7. Searched byte-wise — the
    # surrounding body is deliberately not valid UTF-8.
    marker_run = Bytes[0xC2, 0xA7, 0x53, 0x45, 0x45, 0x44, 0xC2, 0xA7]
    carries_marker = ->(b : Bytes) do
      (0..(b.size - marker_run.size)).any? { |i| b[i, marker_run.size] == marker_run }
    end

    seed = ->(store : Gori::Store) do
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/seed?q=1&r=2", http_version: "HTTP/1.1",
        head: head.to_slice, body: body))
      store.get_flow(id).not_nil!
    end

    it "sends the captured § byte-exact and leaves Content-Length alone" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))

        sent = view.request_bytes
        # The whole request, byte for byte: § kept, CRLF-in-body kept, invalid UTF-8 kept,
        # the captured `$TOKEN` kept, CL still the captured 70.
        String.new(sent).should eq(wire)
        sent.size.should eq(head.bytesize + body.size)
        String.new(sent).should contain("Content-Length: #{body.size}")
        # …and the two § really are still on the wire (c2 a7 SEED c2 a7).
        carries_marker.call(sent).should be_true
      end
    end

    it "reflects the CAPTURED Content-Length in the editor, so ^X hex sends a consistent request" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        # The auto-CL reflection is what ^X snapshots. It used to write the RENDERED (marker-
        # stripped) length into the visible head, so the byte-exact escape hatch shipped a
        # 70-byte body under `Content-Length: 66` — a CL/body desync gori invented out of a
        # benign capture.
        view.request_text.should contain("Content-Length: #{body.size}")
        view.request_text.should_not contain("Content-Length: #{body.size - 4}")

        view.focus_pane(:request)
        view.toggle_request_hex.should be_true # ^X: the byte buffer is authoritative now
        String.new(view.request_bytes).should eq(wire)
      end
    end

    it "does not hand the capture's § to the Fuzzer as an injection position" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        # `space ▸ f` seeds a tab that reads §…§ as syntax; the capture's own § must not
        # become a position there either. The escape `Fuzz::Template` already defines (§§)
        # carries it as a literal, so the template still renders the captured bytes.
        tmpl = Gori::Fuzz::Template.parse(view.fuzz_seed_text)
        tmpl.position_count.should eq(0) # was 1 — the site's own text as a fuzz position
        # …and the escape really does render back to the single captured § (`§§` → `§`).
        # (Compared on the marked region: `Template#render` rebuilds through String, which
        # scrubs the deliberately-invalid UTF-8 further down this fixture's body — a separate
        # concern of the Fuzzer's own seed path, not of the escape.)
        String.new(tmpl.render(tmpl.default_payloads)).should contain(%("mk":"§SEED§"))
        view.fuzz_seed_text.should contain(%("mk":"§§SEED§§"))
        # …and the escape is byte-level: a `String#gsub` here walks CHARS, which rewrites the
        # invalid UTF-8 this capture also carries to U+FFFD (measured: `ff fe 01 02` became
        # `ef bf bd ef bf bd 01 02`, inflating Content-Length with it). Round 4's T1 again.
        seed_bytes = view.fuzz_seed_text.to_slice
        (0..(seed_bytes.size - 4)).any? { |i| seed_bytes[i, 4] == Bytes[0xFF, 0xFE, 0x01, 0x02] }.should be_true
        seed_bytes.size.should eq(wire.bytesize + 4) # exactly the two doubled § (2 bytes each)
      end
    end

    it "keeps the § inert while the operator edits an unrelated header" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        view.focus_pane(:request)
        view.goto_request_line(2) # the Host line
        view.edit_end
        view.edit_insert('x') # an edit is not a marker declaration — see markers_live?
        String.new(view.request_bytes).should contain("Host: h.testx")
        String.new(view.request_bytes).should contain("Content-Length: #{body.size}")
        carries_marker.call(view.request_bytes).should be_true
      end
    end

    it "^A auto-mark refuses by name rather than adopting the capture's § for nothing" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        view.focus_pane(:request)
        # Template.auto_mark is a no-op once ANY § is present, so declaring here would cost
        # the capture's bytes and buy no positions.
        view.auto_mark.should contain("capture's own §")
        view.markers_active?.should be_false
        String.new(view.request_bytes).should eq(wire)
      end
    end

    it "^K on a token DOES declare the buffer a template — and says the § came along" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        view.focus_pane(:request)
        view.goto_request_line(1) # the request line — mark the METHOD token
        msg = view.mark_word
        msg.should contain("marked position")
        msg.should contain("the capture's own § are markers now")
        view.markers_active?.should be_true
        view.request_text.should contain("§POST§")
        # Declared: the capture's § now render like any other marker (visible, and the border
        # chip is lit) — the operator asked for a template.
        String.new(view.request_bytes).should contain(%("mk":"SEED"))
      end
    end

    it "clear-marks refuses on an undeclared capture (it would delete the captured §)" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        view.focus_pane(:request)
        view.clear_marks.should contain("captured data")
        String.new(view.request_bytes).should eq(wire)
      end
    end

    it "COMPLEMENT: the same bytes as a DRAFT still mark, chain and fuzz" do
      draft = RepeaterView.new
      draft.restore("http://h.test",
        "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 99\n\ntok=§secret¦base64-encode§",
        false, true) # evidence: false — the operator typed this
      draft.markers_active?.should be_true
      sent = String.new(draft.request_bytes)
      sent.should contain("tok=c2VjcmV0")
      sent.should contain("Content-Length: 12")
      Gori::Fuzz::Template.parse(draft.fuzz_seed_text).position_count.should eq(1)
    end

    it "COMPLEMENT: a capture with NO § is byte-identical to before the gate" do
      repeater_tmp_store do |store|
        plain = %({"note":"a\r\nb","env":"$TOKEN"})
        h = "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: #{plain.bytesize}\r\n\r\n"
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "POST", target: "/x", http_version: "HTTP/1.1",
          head: h.to_slice, body: plain.to_slice))
        view = RepeaterView.new
        view.load(store.get_flow(id).not_nil!)
        String.new(view.request_bytes).should eq(h + plain)
        view.fuzz_seed_text.should eq(view.request_text)
        view.markers_active?.should be_false
      end
    end
  end

  # The `%%%` twin of the block above, and the reason one flag would not have covered it:
  # `%%%` is draft syntax too — it means "split here" only because the operator typed it.
  # A capture whose body holds a lone `%%%` line was split anyway, which produced the same
  # three harms: the pane showed chunk 1's Content-Length over a whole-buffer send, `^X`
  # snapshotted that head (a CL/body desync invented out of ordinary traffic), and
  # `space ▸ g` manufactured a second request whose REQUEST LINE was the capture's own text.
  # See `RepeaterView#pipeline_live?`.
  describe "%%% in a CAPTURED body is data, not a group separator" do
    body = "line1\r\n%%%\r\nline2" # 17 bytes; the middle line is the capture's, not a split
    head = "POST /p HTTP/1.1\r\nHost: h.test\r\nContent-Length: #{body.bytesize}\r\n\r\n"
    wire = head + body

    seed = ->(store : Gori::Store) do
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/p", http_version: "HTTP/1.1",
        head: head.to_slice, body: body.to_slice))
      store.get_flow(id).not_nil!
    end

    it "reflects the WHOLE buffer's Content-Length, so the pane, ^X and ^R agree" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        # Was `Content-Length: 5` (the pre-`%%%` chunk) in a pane whose ^R sent 17.
        view.request_text.should contain("Content-Length: 17")
        view.request_text.should_not contain("Content-Length: 5")
        String.new(view.request_bytes).should eq(wire)

        view.focus_pane(:request)
        view.toggle_request_hex.should be_true # ^X snapshots the editor buffer
        String.new(view.request_bytes).should eq(wire)
      end
    end

    it "does not split a capture into a request the operator never authored" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        reqs = view.pipeline_requests
        reqs.size.should eq(1) # was 2 — the second's request LINE was the body's `line2`
        reqs.first[0].should eq("POST /p HTTP/1.1")
        String.new(reqs.first[1]).should eq(wire)
      end
    end

    it "DOES split once the operator adds a separator of their own" do
      repeater_tmp_store do |store|
        view = RepeaterView.new
        view.load(seed.call(store))
        # The capture brought one `%%%`; a second one is the operator's, and from then on the
        # buffer is a group draft — captured separator included, which the per-chunk
        # Content-Lengths make visible.
        view.replace_request(wire + "\r\n%%%\r\nGET /second HTTP/1.1\r\nHost: h.test\r\n\r\n")
        reqs = view.pipeline_requests
        reqs.size.should eq(3)
        reqs.last[0].should eq("GET /second HTTP/1.1")
      end
    end

    it "COMPLEMENT: an operator-typed %%% on a DRAFT still splits and still group-sends" do
      view = RepeaterView.new
      view.restore("http://h.test",
        "POST /a HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nx=1\n%%%\nGET /b HTTP/1.1\nHost: h.test\n\n",
        false, true) # evidence: false — the operator typed the separator
      reqs = view.pipeline_requests
      reqs.size.should eq(2)
      reqs[0][0].should eq("POST /a HTTP/1.1")
      reqs[1][0].should eq("GET /b HTTP/1.1")
      String.new(reqs[0][1]).should contain("Content-Length: 3") # per-CHUNK, as before
      view.request_text.should contain("Content-Length: 3")      # …and reflected in the pane
    end

    # The third face, on a DRAFT the operator wrote correctly. `reflect_content_length_in_editor`
    # writes a CHUNK-scoped Content-Length into a buffer that `request_bytes` and the `^X`
    # snapshot both read WHOLE, and one number cannot be right for both framings:
    #
    #   pane        Content-Length: 3    ← chunk 1's body, "AAA"; what `space ▸ g` sends
    #   ^R          Content-Length: 60   ← re-synced whole; self-consistent, but the pane never
    #                                      said 60 and the operator authored TWO requests
    #   ^X then ^R  Content-Length: 3 over a 60-byte body — a desync gori INVENTED
    #
    # So the whole-buffer framing is refused by name. Reflecting the whole-buffer number
    # instead would only move the lie onto `g`, which `reflect_content_length_in_editor`'s own
    # comment calls the worse way round. See `RepeaterView#group_framing_refusal`.
    describe "a %%% buffer is a GROUP — the whole-buffer send is refused, not guessed" do
      draft = "POST /g1 HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nAAA\n" \
              "%%%\nPOST /g2 HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nBB"

      it "refuses ^R by name and names both remedies" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, false, true) # auto-CL ON
        view.request_text.should contain("Content-Length: 3")
        ex = expect_raises(Gori::Fuzz::ChainError, /%%% separator/) { view.request_bytes }
        ex.message.not_nil!.should contain("space ▸ g")
        ex.message.not_nil!.should contain("^L")
      end

      it "refuses the ^X snapshot too — the sharp face, an invented CL/body desync" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, false, true)
        view.focus_pane(:request)
        view.toggle_request_hex.should be_true
        # Was: 110 bytes of `Content-Length: 3` over a 60-byte body, sent verbatim.
        expect_raises(Gori::Fuzz::ChainError, /%%% separator/) { view.request_bytes }
      end

      it "refuses a TRAILING %%% too — where `g` sees only ONE chunk" do
        view = RepeaterView.new
        # The row that rules out any "more than one chunk" predicate: pipeline_requests is 1,
        # yet the pane says 3 and a whole-buffer ^R would frame 7.
        view.restore("http://h.test",
          "POST /g1 HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nAAA\n%%%", false, true)
        view.pipeline_requests.size.should eq(1)
        view.request_text.should contain("Content-Length: 3")
        expect_raises(Gori::Fuzz::ChainError, /%%% separator/) { view.request_bytes }
      end

      it "COMPLEMENT: `space ▸ g` still splits and still sends per-chunk lengths" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, false, true)
        reqs = view.pipeline_requests # does NOT go through request_bytes — unrefused
        reqs.size.should eq(2)
        String.new(reqs[0][1]).should contain("Content-Length: 3")
        String.new(reqs[1][1]).should contain("Content-Length: 2")
      end

      it "COMPLEMENT: auto-CL OFF sends whole, unrefused — gori wrote no number" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, false, false) # ^L off
        # Pane, ^R and g all carry the operator's own 99. Nothing invented ⇒ nothing to refuse,
        # and a literal `%%%` line in a body stays expressible.
        view.request_text.should contain("Content-Length: 99")
        String.new(view.request_bytes).should contain("Content-Length: 99")
        view.request_text.should_not contain("Content-Length: 3")
      end

      it "COMPLEMENT: a draft with NO %%% is byte-identical and never refused" do
        view = RepeaterView.new
        view.restore("http://h.test",
          "POST /g1 HTTP/1.1\nHost: h.test\nContent-Length: 99\n\nAAA", false, true)
        view.request_text.should contain("Content-Length: 3")
        String.new(view.request_bytes).should eq(
          "POST /g1 HTTP/1.1\r\nHost: h.test\r\nContent-Length: 3\r\n\r\nAAA")
      end

      # The THIRD whole-buffer reader. `repeater_minimize` never calls `request_bytes` — it
      # snapshots `request_text` and re-syncs Content-Length over the whole buffer in its own
      # `resolve` — so the framing `^R` refuses ONCE, a minimize did up to SEND_CAP times in
      # one keypress. See `RepeaterView#minimize_refusal`.
      it "refuses MINIMIZE, whose one keypress carries that framing hundreds of times" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, false, true)
        view.minimizable?.should be_false # was true
        view.minimize_refusal.not_nil!.should contain("%%% separator")
        view.minimize_refusal.not_nil!.should contain("several requests as one")
      end

      it "refuses MINIMIZE with auto-CL OFF too — unlike ^R, which stays allowed there" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, false, false)
        # `Minimize.run` reads base_text STRUCTURALLY as one request, so on a group buffer it
        # strips lines out of the operator's SECOND request whatever the Content-Length says.
        # A whole-buffer `^R` with ^L off is a legitimate byte-exact send; this is not.
        view.minimizable?.should be_false
        String.new(view.request_bytes).should contain("Content-Length: 99") # ^R still allowed
      end

      it "COMPLEMENT: minimize still runs on an ordinary request, and names its other refusals" do
        plain = RepeaterView.new
        plain.restore("http://h.test", "GET /a?x=1 HTTP/1.1\nHost: h.test\n\n", false, true)
        plain.minimizable?.should be_true
        plain.minimize_refusal.should be_nil

        marked = RepeaterView.new
        marked.restore("http://h.test", "GET /a?x=§1§ HTTP/1.1\nHost: h.test\n\n", false, true)
        marked.minimizable?.should be_false
        marked.minimize_refusal.not_nil!.should contain("§…§")

        hex = RepeaterView.new
        hex.restore("http://h.test", "GET /a HTTP/1.1\nHost: h.test\n\n", false, true)
        hex.focus_pane(:request)
        hex.toggle_request_hex
        hex.minimize_refusal.not_nil!.should contain("plain HTTP text")
      end

      it "COMPLEMENT: h2 minimizes and sends whole — %%% is not a separator there" do
        view = RepeaterView.new
        view.restore("http://h.test", draft, true, true) # http2: true
        view.minimizable?.should be_true                 # send_pipeline is an h1 primitive
        # 61, not the 60 of the auto-CL-ON group: with no chunking the SECOND request's own
        # `Content-Length: 99` is left as body text rather than resynced to 2.
        view.request_text.should contain("Content-Length: 61")              # pane reads whole-buffer
        String.new(view.request_bytes).should contain("Content-Length: 61") # …and the wire agrees
      end

      # Four surfaces now split or refuse on this separator (TUI group send, TUI minimize,
      # `gori run repeater minimize`, MCP minimize). Two spellings of it was the last drift
      # left in that set, and a separator the TUI and the engine disagreed about would be
      # precisely the "two places decide the split" failure the seam exists to prevent.
      it "shares ONE spelling of the separator with the engine the headless surfaces use" do
        RepeaterView::PIPELINE_SEP.should eq(Gori::Repeater::Minimize::GROUP_SEP)
        # …and they agree on a real buffer, trimming included.
        text = "POST /a HTTP/1.1\nHost: h.test\nContent-Length: 9\n\nx\n  %%%\t\nPOST /b HTTP/1.1\nHost: h.test\n\n"
        Gori::Repeater::Minimize.group_document?(text).should be_true
        view = RepeaterView.new
        view.restore("http://h.test", text, false, true)
        view.pipeline_requests.size.should eq(2)
        view.minimizable?.should be_false
      end

      it "COMPLEMENT: a CAPTURED %%% is inert, so it reflects and sends WHOLE, unrefused" do
        repeater_tmp_store do |store|
          view = RepeaterView.new
          view.load(seed.call(store)) # the capture from the describe above: `line1\r\n%%%\r\nline2`
          view.request_text.should contain("Content-Length: 17")
          String.new(view.request_bytes).should eq(wire) # no refusal — the separator is not live
        end
      end
    end

    it "COMPLEMENT: a capture with NO %%% is byte-identical to before the gate" do
      repeater_tmp_store do |store|
        plain = "line1\r\nline2"
        h = "POST /p HTTP/1.1\r\nHost: h.test\r\nContent-Length: #{plain.bytesize}\r\n\r\n"
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "POST", target: "/p", http_version: "HTTP/1.1",
          head: h.to_slice, body: plain.to_slice))
        view = RepeaterView.new
        view.load(store.get_flow(id).not_nil!)
        String.new(view.request_bytes).should eq(h + plain)
        view.request_text.should contain("Content-Length: 12")
        view.pipeline_requests.size.should eq(1)
      end
    end
  end

  it "CHAIN pane: focus a marker, type a chain, commit writes it back" do
    view = RepeaterView.new
    # marker at offset 0 → set_text zeroes the cursor, so it sits inside §v§
    view.restore("https://a.test", "§v§ HTTP/1.1\nHost: a.test\n\n", false, false)
    view.chain_pane_active?.should be_false
    view.focus_pane(:request)
    view.focus_chain_pane.should be_nil # in a marker → enters the pane (no hint)
    view.chain_pane_active?.should be_true
    "md5".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
    view.commit_chain_pane
    view.chain_pane_active?.should be_false
    view.request_text.should contain("§v¦md5§")
  end

  it "CHAIN pane: esc discards the edit instead of committing it" do
    view = RepeaterView.new
    view.restore("https://a.test", "§v§ HTTP/1.1\nHost: a.test\n\n", false, false)
    view.focus_pane(:request)
    view.focus_chain_pane.should be_nil
    view.chain_pane_active?.should be_true
    "md5".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
    view.discard_chain_pane # esc path
    view.chain_pane_active?.should be_false
    view.request_text.should contain("§v§")     # unchanged — no ¦chain written
    view.request_text.should_not contain("md5") # the typed chain was dropped
  end

  describe "marker structure guard (INS editing)" do
    it "auto-escapes a § typed inside a marker so the ¦chain never leaks" do
      view = RepeaterView.new
      view.restore("https://a.test", "§ab§ HTTP/1.1\nHost: a.test\n\n", false, false)
      view.focus_pane(:request)
      view.edit_move(0, 2) # caret between a and b, inside the value
      view.edit_insert('§')
      view.request_text.lines.first.should eq("§a§§b§ HTTP/1.1")             # §§ escaped literal
      Gori::Fuzz::Template.marked_spans(view.request_text).size.should eq(1) # still ONE marker
    end

    it "flags a backspace/forward-delete that would remove a marker delimiter" do
      view = RepeaterView.new
      view.restore("https://a.test", "§secret¦base64-encode§ HTTP/1.1\nHost: a.test\n\n", false, false)
      view.focus_pane(:request)
      view.edit_move(0, 1) # caret just past the opening §
      view.marker_break_on_backspace.should eq({0, 22})
      view.edit_move(0, 6)                           # caret on the ¦ separator (offset 7)
      view.marker_break_on_delete.should eq({0, 22}) # forward-delete of ¦ would break it
      view.edit_move(0, -4)                          # caret inside "secret" (offset 3)
      view.marker_break_on_backspace.should be_nil   # a value byte is not a delimiter
    end

    it "strips the WHOLE marker (both § and ¦chain) on confirm, keeping only the value" do
      view = RepeaterView.new
      view.restore("https://a.test", "§secret¦base64-encode§ HTTP/1.1\nHost: a.test\n\n", false, false)
      view.focus_pane(:request)
      view.strip_marker_span({0, 22})
      view.request_text.lines.first.should eq("secret HTTP/1.1")
      Gori::Fuzz::Template.marked_spans(view.request_text).should be_empty
    end
  end

  it "CHAIN pane hints when the cursor isn't in a §…§ marker" do
    view = RepeaterView.new
    view.restore("https://a.test", "GET / HTTP/1.1\n\n", false, false)
    view.focus_pane(:request)
    view.focus_chain_pane.should_not be_nil # no marker under the cursor → hint, not activated
    view.chain_pane_active?.should be_false
  end

  it "conceals the ¦chain inline and reveals it in the caret tooltip (only §value§ shows)" do
    view = RepeaterView.new
    view.restore("https://a.test", "§v¦md5§ HTTP/1.1\nHost: a.test\n\n", false, false)
    view.focus_pane(:request) # cursor at offset 0 sits inside the §v¦md5§ marker
    b = MemoryBackend.new(120, 24)
    view.render(Screen.new(b), Rect.new(0, 0, 120, 24))
    grid = (0...24).map { |y| b.row(y) }.join("\n")
    # The request line renders §v§ (the ¦md5 hidden inline), never the full §v¦md5§.
    grid.should contain("§v§ HTTP/1.1")
    grid.should_not contain("§v¦md5§")
    # ...but the caret tooltip reveals the concealed chain + the ^Y edit affordance.
    grid.should contain("md5")         # chain shown in the tooltip
    grid.should contain("^Y edit")     # edit affordance
    grid.should_not contain("PREVIEW") # the ^Y modal is NOT auto-shown
  end

  it "opens the CHAIN modal (with a transform preview) only after ^Y" do
    view = RepeaterView.new
    view.restore("https://a.test", "§v¦md5§ HTTP/1.1\nHost: a.test\n\n", false, false)
    view.focus_pane(:request)
    view.focus_chain_pane.should be_nil # in a marker → opens the editor (no hint)
    b = MemoryBackend.new(120, 24)
    view.render(Screen.new(b), Rect.new(0, 0, 120, 24))
    grid = (0...24).map { |y| b.row(y) }.join("\n")
    grid.should contain("CHAIN")   # modal title
    grid.should contain("PREVIEW") # live transform preview
  end

  it "load_grpc keeps the framed body byte-exact and the head editable" do
    repeater_tmp_store do |store|
      # one gRPC message: 1-byte flag + 4-byte len(3) + payload incl a non-UTF-8 0xFF
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0x01, 0x02]
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/demo.Greeter/SayHello", http_version: "HTTP/2",
        head: "POST /demo.Greeter/SayHello HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\nte: trailers\r\n\r\n".to_slice,
        body: body))
      detail = store.get_flow(id).not_nil!

      view = RepeaterView.new
      view.load_grpc(detail)
      view.grpc_mode?.should be_true
      view.http2?.should be_true

      sent = view.request_bytes
      String.new(sent).should contain("content-type: application/grpc")
      # the framed body is re-appended VERBATIM (a text round-trip would scrub 0xFF)
      sent[(sent.size - body.size)..].should eq(body)
      sent.includes?(0xFF_u8).should be_true
    end
  end

  it "reframes an edited unary gRPC payload with a corrected length prefix" do
    repeater_tmp_store do |store|
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0x01, 0x02] # one message, payload 0xFF 01 02
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/S/M", http_version: "HTTP/2",
        head: "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: body))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      view.grpc_reframable?.should be_true

      # unmodified: the reframed body matches the captured framing byte-for-byte
      s0 = view.request_bytes
      s0[(s0.size - body.size)..].should eq(body)

      # hex-edit the payload: overtype 0xFF → 0xAB (length unchanged → prefix stays 3)
      view.toggle_request_hex.should be_true
      view.hex_set_nibble('a')
      view.hex_set_nibble('b')
      view.toggle_request_hex.should be_false # exit writes the edited payload back
      sent = view.request_bytes
      sent[(sent.size - 8)..].should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0xAB, 0x01, 0x02])
    end
  end

  it "pipeline_requests splits the editor on lone %%% lines and labels each request" do
    view = RepeaterView.new
    req = "GET /a HTTP/1.1\nHost: h\n\n%%%\nGET /b HTTP/1.1\nHost: h\n\n"
    view.restore("http://127.0.0.1", req, false, false)
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    reqs[0][0].should eq("GET /a HTTP/1.1") # label = the request line
    reqs[1][0].should eq("GET /b HTTP/1.1")
    # a bodyless head gets its CRLFCRLF terminator (the blank line is consumed by the split)
    String.new(reqs[0][1]).should eq("GET /a HTTP/1.1\r\nHost: h\r\n\r\n")
    String.new(reqs[1][1]).should eq("GET /b HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  # The group split cuts the buffer on line boundaries, so it has to carry each line's own
  # terminator across the cut — otherwise a chunk's BODY came out LF-joined and its
  # Content-Length was resynced down, exactly like the single send did.
  it "pipeline_requests keeps each chunk's body terminators" do
    view = RepeaterView.new
    # The newline before `%%%` belongs to the separator, so the chunk body is `b1\r\nb2` — 6
    # bytes, and auto-CL must agree with that rather than with the 4 an LF-joined body had.
    req = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\n\r\nb1\r\nb2\r\n" \
          "%%%\r\nGET /b HTTP/1.1\r\nHost: h\r\n\r\n"
    view.restore("http://127.0.0.1", req, false, true) # auto-CL on: it must not shrink
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    String.new(reqs[0][1]).should eq("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 6\r\n\r\nb1\r\nb2")
    String.new(reqs[1][1]).should eq("GET /b HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  # N1: auto-Content-Length reflected over the WHOLE buffer, so on a `%%%` send-group the
  # first request's VISIBLE Content-Length covered its body, the separator and the entire
  # second request (3 → 62). `pipeline_requests` framed each chunk correctly, so the wire was
  # right and the editor lied — and chunk 2 onwards was never reflected at all.
  it "reflects auto-Content-Length per %%% chunk, not over the whole buffer" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1",
      "POST /g1 HTTP/1.1\nHost: h\nContent-Length: 99\n\nAAA\n" \
      "%%%\n" \
      "POST /g2 HTTP/1.1\nHost: h\nContent-Length: 7\n\nBB\n",
      false, true) # auto-CL ON → restore reflects
    lines = view.request_text.split('\n')
    lines.should contain("Content-Length: 3") # "AAA", not 62
    lines.should contain("Content-Length: 2") # "BB" — the second chunk is reflected too
    reqs = view.pipeline_requests
    String.new(reqs[0][1]).should end_with("Content-Length: 3\r\n\r\nAAA")
    String.new(reqs[1][1]).should end_with("Content-Length: 2\r\n\r\nBB")
  end

  # The other side of that: WITHOUT a separator, ^R sends the whole buffer including a
  # trailing newline, so the reflection must not borrow the group split's blank-edge trim.
  # It read 32 for a body of 34 while the send framed 34 — the same lie, reversed.
  it "reflects auto-Content-Length over the whole buffer when there is no %%% separator" do
    view = RepeaterView.new
    body = "line1\r\nline2\r\n\r\ntail-after-blank\r\n" # 34 bytes, ENDS in a newline
    req = "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\n#{body}"
    view.restore("http://127.0.0.1", req, false, true)
    view.request_text.split("\r\n").should contain("Content-Length: 34")
    String.new(view.request_bytes).should eq(req.sub("Content-Length: 99", "Content-Length: 34"))
  end

  # F1: the Repeater's ^R is documented as a byte-exact resend. A captured body is opaque
  # bytes; only the head is line-structured. The editor used to delete every CR at LOAD, so
  # `line1\r\nline2` went out as `line1\nline2` under a Content-Length silently resynced DOWN
  # to match — request smuggling, CRLF-in-body and any 0x0D-bearing format were untestable.
  it "resends a captured CRLF body byte-exact, with Content-Length untouched" do
    view = RepeaterView.new
    req = "POST /crlfbody HTTP/1.1\r\nHost: h\r\nContent-Length: 34\r\n\r\n" \
          "line1\r\nline2\r\n\r\ntail-after-blank\r\n"
    view.restore("http://127.0.0.1", req, false, true) # auto-Content-Length ON
    String.new(view.request_bytes).should eq(req)
  end

  # The same defect had a SECOND site, upstream of the editor: `origin_form_text` split the
  # whole captured message into lines and re-joined them with LF before set_text ever saw it,
  # so the bytes were already gone by the time anything careful ran. Only the request LINE is
  # rewritten (absolute-form → origin-form); everything after it is passed through verbatim.
  it "loads a captured flow without flattening the body, absolute-form request line and all" do
    repeater_tmp_store do |store|
      body = "line1\r\nline2\r\n\r\ntail\r\n" # 22 bytes
      head = "POST http://h.test/crlf HTTP/1.1\r\nHost: h.test\r\nContent-Length: 22\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/crlf", http_version: "HTTP/1.1",
        head: head.to_slice, body: body.to_slice))
      view = RepeaterView.new
      view.load(store.get_flow(id).not_nil!)
      String.new(view.request_bytes).should eq(
        "POST /crlf HTTP/1.1\r\nHost: h.test\r\nContent-Length: 22\r\n\r\n#{body}")
    end
  end

  it "keeps a bare LF in a body a bare LF, beside the CRs" do
    view = RepeaterView.new
    req = "POST /b HTTP/1.1\r\nHost: h\r\nContent-Length: 12\r\n\r\nA\u0000B\tC\r\nD\nE(F"
    view.restore("http://127.0.0.1", req, false, true)
    String.new(view.request_bytes).should eq(req)
  end

  # F2: hex mode is the documented byte-exact escape hatch ("sends exactly what you type"),
  # and it snapshotted the TextArea re-joined with CRLF — inventing an 0x0D in front of every
  # bare LF in the body. With auto-CL deliberately off in hex mode, those invented bytes
  # shipped under the older, shorter Content-Length and the remainder was left on the socket
  # for the origin to read as the next request.
  it "snapshots the ORIGINAL wire bytes into hex mode, not a CRLF re-join" do
    view = RepeaterView.new
    req = "POST /b HTTP/1.1\r\nHost: h\r\nContent-Length: 12\r\n\r\nA\u0000B\tC\r\nD\nE(F"
    view.restore("http://127.0.0.1", req, false, false)
    view.toggle_request_hex.should be_true
    String.new(view.request_bytes).should eq(req) # hex bytes ARE the request bytes
    view.toggle_request_hex.should be_false       # and the trip back is lossless too
    String.new(view.request_bytes).should eq(req)
  end

  it "pipeline_requests keeps a bodied request's separator (no double terminator)" do
    view = RepeaterView.new
    req = "POST /a HTTP/1.1\nHost: h\nContent-Length: 4\n\ndata\n%%%\nGET /b HTTP/1.1\nHost: h\n"
    view.restore("http://127.0.0.1", req, false, false)
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    String.new(reqs[0][1]).should eq("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\ndata")
    String.new(reqs[1][1]).should eq("GET /b HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "group_sendable? is false in h2 / hex / gRPC modes" do
    view = RepeaterView.new
    view.load_blank
    view.group_sendable?.should be_true
    view.toggle_http2 # h2 → send_pipeline is an h1 primitive
    view.group_sendable?.should be_false
  end

  it "apply_group shows a per-response transcript and a single ^R send reclaims the pane" do
    view = RepeaterView.new
    view.load_blank
    head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    r1 = Gori::Repeater::Result.new(head, "hi".to_slice, resp, 1_000_i64)
    r2 = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connect failed")
    view.apply_group([{"GET /a HTTP/1.1", r1}, {"GET /b HTTP/1.1", r2}])

    view.group_mode?.should be_true
    lines = view.resp_plain_lines
    lines.any?(&.includes?("req 1 · GET /a HTTP/1.1")).should be_true
    lines.any?(&.includes?("HTTP 200")).should be_true
    lines.any?(&.includes?("req 2 · GET /b HTTP/1.1")).should be_true
    lines.any?(&.includes?("connect failed")).should be_true

    # a normal single send takes the response pane back from the group transcript
    view.apply(Gori::Repeater::Result.new(head, "hi".to_slice, resp, 1_000_i64))
    view.group_mode?.should be_false
  end

  it "does not reframe a multi-message gRPC body — verbatim, hex refused" do
    repeater_tmp_store do |store|
      body = Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0xAA,
        0x00, 0x00, 0x00, 0x00, 0x01, 0xBB] # two framed messages
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/S/M", http_version: "HTTP/2",
        head: "POST /S/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: body))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)
      view.grpc_reframable?.should be_false
      view.toggle_request_hex.should be_false # nothing single-payload to edit
      sent = view.request_bytes
      sent[(sent.size - body.size)..].should eq(body)
    end
  end

  it "toggle_http2 flips the transport and retargets the request-line version token" do
    view = RepeaterView.new
    view.load_blank
    view.http2?.should be_false
    view.request_text.should contain("HTTP/1.1")

    view.toggle_http2.should be_true
    view.http2?.should be_true
    view.request_text.lines.first.should end_with("HTTP/2")
    view.request_text.should_not contain("HTTP/1.1")

    view.toggle_http2.should be_false
    view.http2?.should be_false
    view.request_text.lines.first.should end_with("HTTP/1.1")
  end

  it "toggle_http2 is refused for gRPC (h2) and WebSocket (h1) — the transport is intrinsic" do
    repeater_tmp_store do |store|
      gid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/demo.Greeter/SayHello", http_version: "HTTP/2",
        head: "POST /demo.Greeter/SayHello HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: Bytes[0x00, 0x00, 0x00, 0x00, 0x00]))
      gview = RepeaterView.new
      gview.load_grpc(store.get_flow(gid).not_nil!)
      gview.toggle_http2.should be_true # stays h2 — no flip
      gview.http2?.should be_true

      wid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 2_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      wview = RepeaterView.new
      wview.load_ws(store.get_flow(wid).not_nil!, [] of Gori::Store::WsOutMessage)
      wview.toggle_http2.should be_false # stays h1 — no flip
      wview.http2?.should be_false
    end
  end

  it "ws_out_messages yields one clean frame per line and labels the tab by the upgrade request" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws/chat", http_version: "HTTP/1.1",
        head: "GET /ws/chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!,
        ["{\"a\":1}", "ping"].map { |t| Gori::Store::WsOutMessage.text(t) })

      msgs = view.ws_out_messages
      msgs.size.should eq(2)
      # the editor joins with CRLF, so a naive split would leave a trailing '\r' on
      # every frame but the last — these must be clean.
      String.new(msgs[0].payload).should eq("{\"a\":1}")
      String.new(msgs[1].payload).should eq("ping")
      # the sub-tab label is the upgrade request line, NOT the first message
      view.summary.should eq("GET /ws/chat")
    end
  end

  it "replays a captured BINARY message an untouched pane never showed, and KEEPS it once edited" do
    # The pane is a text projection — one message per line, LF-split — so it cannot carry a
    # binary payload. Sending the projection back was how a captured binary message became
    # an opcode-1 text one on every save, and how it vanished from every later replay. The
    # rule is the WS relay's: gori's own shape only for what the operator actually changed.
    #
    # That last sentence is why the "once edited" half of this spec inverted: an edit to a
    # TEXT line is not a change to the BINARY frame beside it, and treating it as one deleted
    # the frame from the wire and (on a persisted session) from the database. An edit is now
    # a position-keyed splice over the seed, so the binary frame keeps its slot.
    bin = Bytes[0x00, 0xFF, 0x0A, 0x41]
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!, [
        Gori::Store::WsOutMessage.text("first"),
        Gori::Store::WsOutMessage.new(2, bin),
      ])

      view.ws_out_messages.map(&.opcode).should eq([1, 2])
      view.ws_out_messages[1].payload.should eq(bin)
      view.ws_out_messages_raw.map(&.opcode).should eq([1, 2]) # what a save would persist
      view.ws_out_messages_raw[1].payload.should eq(bin)

      # Editing the TEXT line changes that line and nothing else.
      view.edit_insert('X')
      view.ws_out_messages.map(&.opcode).should eq([1, 2])
      String.new(view.ws_out_messages[0].payload).should eq("Xfirst")
      view.ws_out_messages[1].payload.should eq(bin)
      view.ws_out_messages_raw.map(&.opcode).should eq([1, 2])
      view.ws_out_messages_raw[1].payload.should eq(bin)
    end
  end

  it "carries a binary out-frame's invalid UTF-8 byte-exact into a wscat -x command" do
    # `RepeaterController#repeater_request_options` turns each `ws_out_messages` payload into
    # the `String` `CopyMenu.request_options` feeds to `wscat_command`. That String used to go
    # through `.scrub` first, so "Copy as wscat" of a binary out-frame handed the operator a
    # command that did not reproduce what gori actually sent — the same defect a round-7 fixer
    # closed for "Copy as cURL"'s `--data-raw` (see `CopyMenu.shell_quote`'s comment). Fixed by
    # dropping the controller's `.scrub`, since `shell_quote` is byte-safe on its own. This
    # reproduces the controller's exact composition — `RepeaterView` for the frame, the
    # controller's own map expression, then the real (unmodified) `CopyMenu` — without needing
    # a full `Host` (no spec anywhere constructs a TUI controller; see `tab_controller.cr`).
    bin = Bytes[0xff_u8, 0xfe_u8, 0x01_u8, 0x02_u8]
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws", http_version: "HTTP/1.1",
        head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!, [Gori::Store::WsOutMessage.new(2, bin)])

      # The exact expression now in `repeater_controller.cr` (`String.new`, not `.scrub`).
      ws_messages = view.ws_out_messages.map { |message| String.new(message.payload) }
      opts = Gori::Tui::CopyMenu.request_options(
        String.new(view.request_bytes), "https://ws.test", websocket_messages: ws_messages)
      wscat = opts.find! { |o| o.key == 'w' }
      wscat.text.to_slice.hexstring.should contain(bin.hexstring)
      wscat.text.to_slice.hexstring.should_not contain("efbfbd")
    end
  end

  it "keeps an unsaved message edit when a peer's request-side change reconciles in" do
    # `apply_peer_request` runs on every cross-session request-side change and re-seeds the
    # message pane. Adopting the peer's messages under an unsaved local edit would send
    # THEIRS while showing OURS — the pane's own `set_text` guard already refused to clobber
    # the text, and the seed has to refuse alongside it.
    view = RepeaterView.new
    ws = "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n"
    view.restore("https://ws.test", ws, false, true,
      ws_messages: [Gori::Store::WsOutMessage.text("mine")])
    view.focus_pane(:request) # restore lands on :target; the message pane is under :request
    view.edit_insert('!')
    String.new(view.ws_out_messages[0].payload).should eq("!mine")

    view.apply_peer_request("https://ws.test", ws + "X-Peer: 1\r\n", false, true,
      ws_messages: [Gori::Store::WsOutMessage.text("theirs")])
    view.ws_out_messages.size.should eq(1)
    String.new(view.ws_out_messages[0].payload).should eq("!mine")
  end

  it "allows editing both handshake request and messages in ws_mode" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/ws/chat", http_version: "HTTP/1.1",
        head: "GET /ws/chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice, body: nil))
      view = RepeaterView.new
      view.load_ws(store.get_flow(id).not_nil!,
        ["{\"a\":1}", "ping"].map { |t| Gori::Store::WsOutMessage.text(t) })

      view.ws_mode?.should be_true
      view.req_pane.should eq(:decoded)

      view.edit_insert('!')
      view.dirty?.should be_true
      msgs = view.ws_out_messages
      msgs.size.should eq(2)
      String.new(msgs[0].payload).should eq("!{\"a\":1}")

      view.clear_dirty
      view.dirty?.should be_false

      view.toggle_req_pane.should eq(:envelope)
      view.edit_insert('X')
      view.dirty?.should be_true
      String.new(view.ws_upgrade_bytes).should contain("XGET /ws/chat HTTP/1.1")
    end
  end

  it "renders a gRPC response as deframed messages + grpc-status" do
    repeater_tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "POST", target: "/svc/M", http_version: "HTTP/2",
        head: "POST /svc/M HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n".to_slice,
        body: Bytes[0x00, 0x00, 0x00, 0x00, 0x01, 0x41]))
      view = RepeaterView.new
      view.load_grpc(store.get_flow(id).not_nil!)

      # a framed "Hello!" response + grpc-status 0 trailer (as H2Engine synthesises it)
      msg = "Hello!".to_slice
      body = IO::Memory.new
      body.write(Bytes[0x00, 0x00, 0x00, 0x00, msg.size.to_u8])
      body.write(msg)
      head = "HTTP/2 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\ngrpc-message: OK\r\n\r\n"
      resp = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
      view.apply(Gori::Repeater::Result.new(head.to_slice, body.to_slice, resp, 5000_i64))

      backend = MemoryBackend.new(160, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
      backend.contains?("GRPC RESPONSE").should be_true
      backend.contains?("message #1").should be_true # deframed response message
      backend.contains?("Hello!").should be_true     # ASCII in the hex preview
      backend.contains?("grpc-status: 0 OK").should be_true
    end
  end

  it "restore re-opens a persisted tab and starts clean (not dirty)" do
    view = RepeaterView.new
    view.restore("https://api.test", "POST /x HTTP/1.1\nHost: api.test\n\nbody", true, false)
    view.loaded?.should be_true
    view.target.should eq("https://api.test")
    view.request_text.should eq("POST /x HTTP/1.1\nHost: api.test\n\nbody")
    view.http2?.should be_true
    view.auto_content_length?.should be_false
    view.dirty?.should be_false # synced/restored text must never be re-saved by us
  end

  it "restore with no persisted response starts the pane empty" do
    view = RepeaterView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("— not sent — press ^R to resend —").should be_true
  end

  it "restore re-populates a persisted last response (survives a reopen)" do
    view = RepeaterView.new
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true,
      head, "RESTORED".to_slice, nil, 1234_i64)
    view.dirty?.should be_false # a restored tab must never be re-saved
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("RESTORED").should be_true
    backend.contains?("— not sent —").should be_false
  end

  it "restore shows a persisted errored send" do
    view = RepeaterView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true,
      Bytes.empty, nil, "connect failed: api.test:443", 0_i64)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("repeater error: connect failed: api.test:443").should be_true
  end

  it "seed_original re-arms the captured-original diff baseline after restore (reopened ^R tab)" do
    view = RepeaterView.new
    # reopened, never-sent History tab: restore() alone is non-diffable …
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    orig_head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.seed_original(orig_head, "ORIGINAL".to_slice) # … the Runner re-seeds it from flow_id

    sent = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "CHANGED".to_slice, nil, 1000_i64)
    view.apply(sent)      # first resend after reopen → baseline is the seeded original
    view.toggle_resp_mode # response → diff

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("- ORIGINAL").should be_true # diffs against the captured original, not nothing
    backend.contains?("+ CHANGED").should be_true
  end

  it "seed_original is a no-op when the source flow captured no response" do
    view = RepeaterView.new
    view.restore("https://api.test", "GET / HTTP/1.1\n\n", false, true)
    view.seed_original(nil, nil) # flow without a response → stays non-diffable
    ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "X".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.toggle_resp_mode # → diff
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("first send").should be_true # nothing to diff against yet
  end

  it "marks dirty on edits + flag toggles, and clears on restore" do
    view = RepeaterView.new
    view.load_blank
    view.dirty?.should be_false # a freshly opened tab is clean (persisted on creation)

    view.focus_first # :target
    view.target_insert('x')
    view.dirty?.should be_true
    view.clear_dirty

    view.pane_advance(1) # :target → :request
    view.edit_insert('y')
    view.dirty?.should be_true
    view.clear_dirty

    view.toggle_auto_content_length
    view.dirty?.should be_true

    view.restore("https://z.test", "GET / HTTP/1.1\n\n", false, true)
    view.dirty?.should be_false
  end

  it "label uses the custom name when set, else the request summary" do
    view = RepeaterView.new
    view.load_blank
    view.label(18).should eq("GET /") # auto-derived from the request line
    view.name = "auth flow"
    view.label(18).should eq("auth flow")
    view.name = "   " # blank → revert to the auto label
    view.label(18).should eq("GET /")
    view.name = nil
    view.label(18).should eq("GET /")
  end

  it "label truncates a long custom name" do
    view = RepeaterView.new
    view.load_blank
    view.name = "a-very-long-custom-tab-name"
    label = view.label(8)
    label.size.should be <= 8
    label.should end_with("…")
  end

  it "persists a repeater tab's custom name (set / clear)" do
    repeater_tmp_store do |store|
      id = store.insert_repeater("http://h/x", "GET /x HTTP/1.1".to_slice, false, true, nil, 0)
      store.set_repeater_name(id, "my-tab")
      store.repeaters.first.name.should eq("my-tab")
      store.set_repeater_name(id, nil) # blank clears the custom name
      store.repeaters.first.name.should be_nil
    end
  end

  it "shows the response duration and size on the RESPONSE pane after a send" do
    view = RepeaterView.new
    view.load_blank
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    body = ("x" * 2048).to_slice
    view.apply(Gori::Repeater::Result.new(head, body, nil, 234_000_i64)) # 234 ms, head+body ≈ 2 KB

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("234ms").should be_true
    backend.contains?("KB").should be_true
  end

  it "edits and exposes an SNI override (^S sub-field of the target)" do
    view = RepeaterView.new
    view.load_blank # focus starts on :target
    view.sni_override.should be_nil
    view.editing_sni?.should be_false

    view.toggle_sni_field # ^S → edit the SNI host
    view.editing_sni?.should be_true
    "evil.com".each_char { |c| view.target_insert(c) }
    view.sni.should eq("evil.com")               # the SNI field took the input, not the URL
    view.target.should eq("https://example.com") # URL untouched
    view.sni_override.should eq("evil.com")
    view.dirty?.should be_true

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("SNI").should be_true
    backend.contains?("evil.com").should be_true
  end

  it "leaving the target pane exits the SNI sub-field (URL edits never land in SNI)" do
    view = RepeaterView.new
    view.load_blank
    view.toggle_sni_field
    "evil.com".each_char { |c| view.target_insert(c) }
    view.editing_sni?.should be_true

    view.pane_advance(1) # ↓/Tab down into the request pane
    view.editing_sni?.should be_false
    view.focus_first # …then back up to the target pane

    view.editing_sni?.should be_false # arrives on the URL field, not the stale SNI sub-field
    view.target_insert('Z')           # a URL keystroke must edit the URL…
    view.target.should eq("https://example.comZ")
    view.sni.should eq("evil.com") # …and leave the SNI value untouched
  end

  it "a click on the TARGET card's bottom border does not enter the SNI sub-field" do
    view = RepeaterView.new
    view.restore("https://10.0.0.5", "GET / HTTP/1.1\n\n", false, true, sni: "evil.com")
    rect = Rect.new(0, 0, 120, 20)
    # With an SNI override the card is 4 rows: border@y, URL@y+1, SNI@y+2, border@y+3.
    view.target_click_to_cursor(rect, 5, rect.y + 3) # the decorative bottom border
    view.editing_sni?.should be_false                # …must NOT switch to the SNI field
    view.target_click_to_cursor(rect, 5, rect.y + 2) # the real SNI row does
    view.editing_sni?.should be_true
  end

  it "restore seeds a persisted SNI override and shows it" do
    view = RepeaterView.new
    view.restore("https://10.0.0.5", "GET / HTTP/1.1\n\n", false, true, sni: "evil.com")
    view.sni_override.should eq("evil.com")
    view.dirty?.should be_false # a restored tab must never be re-saved

    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("evil.com").should be_true
  end

  it "persists a repeater tab's SNI override (set / clear)" do
    repeater_tmp_store do |store|
      id = store.insert_repeater("https://h/x", "GET /x HTTP/1.1".to_slice, false, true, nil, 0, "evil.com")
      store.repeaters.first.sni.should eq("evil.com")
      store.repeaters_meta.first.sni.should eq("evil.com")                                   # syncs via the fast reconcile poll too
      store.update_repeater(id, "https://h/x", "GET /x HTTP/1.1".to_slice, false, true, nil) # clear
      store.repeaters.first.sni.should be_nil
    end
  end

  # ASSERTION INVERTED BY SOFT WRAP. This pinned the old behaviour exactly: a body line
  # wider than the pane was CLIPPED ("TAIL" absent) until ⇧→ scrolled it in, at which point
  # the head disappeared. Both halves of that are now wrong on purpose — the response pane
  # wraps, so the head and the tail of one logical line are on screen together and there is
  # no state in which either is unreachable. `hscroll` survives only as a no-op stub for the
  # still-registered chord, so calling it must change nothing.
  it "wraps a long response body line instead of clipping it (no horizontal scroll)" do
    view = RepeaterView.new
    view.load_blank
    long_line = "HEAD" + ("." * 60) + "TAIL"
    ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, long_line.to_slice, nil, 1000_i64)
    view.apply(ok)

    rect = Rect.new(0, 0, 40, 20)
    backend = MemoryBackend.new(40, 20)
    view.render(Screen.new(backend), rect)
    backend.contains?("HEAD").should be_true
    backend.contains?("TAIL").should be_true # on a continuation row, not off the right edge

    # `hscroll` and its ⇧←/→ binding are GONE, not stubbed. Leaving the no-op in place was
    # worse than dead code: `handle_repeater_response_hscroll` ran BEFORE the response pane's
    # key ladder and returned true for ⇧←/→, so it swallowed the chord that the ladder maps to
    # `resp_nav_step(..., selecting: true)`. Horizontal selection in the response pane was
    # silently inert for as long as the stub existed. Removing both restores it; the wrap
    # assertion above no longer needs a scroll call to be meaningful, because there is no
    # state in which the tail is off-screen.
    view.responds_to?(:hscroll).should be_false
  end

  it "defaults request and target to READ mode" do
    view = RepeaterView.new
    view.load_blank
    view.request_insert?.should be_false
    view.target_insert?.should be_false
  end

  it "toggles INS mode and shows the badge on the request pane" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:request)
    view.enter_request_insert!
    backend = MemoryBackend.new(120, 24)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 24))
    backend.contains?("INS").should be_true
    backend.contains?("i:INS").should be_false
    view.exit_request_insert!
    view.request_insert?.should be_false
    backend2 = MemoryBackend.new(120, 24)
    view.render(Screen.new(backend2), Rect.new(0, 0, 120, 24))
    backend2.contains?("↵:NOR").should be_true
  end

  it "resp_move + selection returns plain text for copy" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "LINE1\nLINE2".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus_pane(:response)
    lines = view.resp_plain_lines
    lines.should_not be_empty
    view.resp_move(0, 0)
    view.resp_copy_text.should eq(lines[0])
    view.resp_move(0, 4, selecting: true)
    view.resp_copy_text.should eq(lines[0][0, 4])
  end

  it "^G go-to-line in the response pane also moves the caret (not just the scroll)" do
    view = RepeaterView.new
    view.load_blank
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, "LINE1\nLINE2\nLINE3\nLINE4".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus_pane(:response)
    line3 = view.response_search_lines("LINE3").first # 0-based row of the body's 3rd line

    view.goto_response_line(line3 + 1) # 1-based
    view.resp_copy_text.should eq("LINE3")
    view.resp_move(-1, 0) # ↑ should step to LINE2, not jump from a stale pre-goto caret
    view.resp_copy_text.should eq("LINE2")
  end

  it "apply_peer_request keeps live response + focus (reconcile must not wipe a send)" do
    # Regression: reconcile used full restore() for request-side sync. restore() always
    # sets focus=:target and clears @result when no response BLOBs are passed — so a
    # post-send data_version poll (update_repeater_response bumps it) looked like the
    # response was reset and focus jumped to Target.
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    ok = Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64)
    view.apply(ok)
    view.focus_pane(:response)

    view.apply_peer_request("https://peer.example", "GET /peer HTTP/1.1\nHost: peer.example\n\n",
      false, true, sni: "")

    view.focus.should eq(:response)
    view.target.should eq("https://peer.example")
    view.request_text.should contain("GET /peer")
    # Response still present and renderable
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    backend.contains?("PONG").should be_true
    backend.contains?("— not sent —").should be_false
  end

  it "request_side_matches? treats empty SNI nil and \"\" as equal" do
    view = RepeaterView.new
    view.load_blank
    view.request_side_matches?(view.target, view.request_text, view.http2?,
      view.auto_content_length?, nil).should be_true
    view.request_side_matches?(view.target, view.request_text, view.http2?,
      view.auto_content_length?, "").should be_true
    view.request_side_matches?(view.target, view.request_text, view.http2?,
      view.auto_content_length?, "evil.com").should be_false
  end

  it "post-send store response write + peer request sync keeps the applied result" do
    # End-to-end shape of drain_results + reconcile without a full Host:
    # apply → persist response → apply_peer_request (what reconcile does on mismatch).
    path = File.tempname("gori-send-sync", ".db")
    store = Gori::Store.open(path)
    begin
      view = RepeaterView.new
      view.load_blank
      rid = store.insert_repeater(view.target, view.request_text.to_slice, view.http2?, view.auto_content_length?,
        nil, 0, view.sni_override)
      view.clear_dirty
      ok = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "KEEPME".to_slice, nil, 500_i64)
      view.apply(ok)
      view.focus_pane(:response)
      store.update_repeater_response(rid, ok.head, ok.body, nil, ok.duration_us)
      store.flush

      row = store.repeaters_meta.find { |r| r.id == rid }.not_nil!
      # Own row still matches → reconcile would skip. Force a peer-like request edit.
      store.update_repeater(rid, "https://peer.test", "GET /from-peer HTTP/1.1\nHost: peer.test\n\n".to_slice,
        false, true, nil)
      store.flush
      row = store.repeaters_meta.find { |r| r.id == rid }.not_nil!
      row_request_text = String.new(row.request)
      view.request_side_matches?(row.target, row_request_text, row.http2?,
        row.auto_content_length?, row.sni).should be_false

      view.apply_peer_request(row.target, row_request_text, row.http2?, row.auto_content_length?,
        sni: row.sni || "")
      view.focus.should eq(:response)
      view.target.should eq("https://peer.test")
      backend = MemoryBackend.new(120, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
      backend.contains?("KEEPME").should be_true
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "focused large-body paint + wheel scroll stay windowed (no full rematerialise)" do
    # Regression: paint_resp_line_chrome used to call resp_plain_lines once per
    # visible row every frame — with BodyLines that re-materialised ~N lines × H
    # rows (~300ms+ for 50k). Focused render + resp_scroll_view must stay far below
    # that full-body cost (same bar as History visible-only path).
    view = RepeaterView.new
    view.load_blank
    line = ("w" * 20) + "\n"
    n = 30_000
    io = IO::Memory.new(line.bytesize * n)
    n.times { io << line }
    body = io.to_slice
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice
    view.apply(Gori::Repeater::Result.new(head, body, nil, 1000_i64))
    view.focus_pane(:response)
    view.resp_line_source[0].should be > 25_000

    rect = Rect.new(0, 0, 120, 30)
    backend = MemoryBackend.new(120, 30)
    t0 = Time.instant
    5.times do |frame|
      view.resp_scroll_view(40) if frame > 0
      view.render(Screen.new(backend), rect)
    end
    paint_ms = (Time.instant - t0).total_milliseconds
    paint_ms.should be < 2_000.0

    t1 = Time.instant
    200.times { view.resp_move(1, 0) }
    move_ms = (Time.instant - t1).total_milliseconds
    move_ms.should be < 500.0

    backend.contains?("RESPONSE").should be_true
  end

  # Everything below is about text that came from ANOTHER tool's clipboard. The editor is a
  # line buffer (TextArea strips \r off every line), so a request pasted from Burp reaches
  # the wire only through these three repairs; without them the origin answers 400 and the
  # only visible symptom is a status code.
  describe "requests pasted from another tool" do
    it "terminates a head-only request that has no trailing blank line" do
      view = RepeaterView.new
      view.restore("http://h.test", "GET /x HTTP/1.1\nHost: h.test", false, true)

      # Without the terminator the origin waits for more headers until something times out:
      # the user sees "no response", the origin logs a 400/408.
      String.new(view.request_bytes).should eq("GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n")
    end

    it "terminates once, whatever trailing newlines the paste carried" do
      view = RepeaterView.new
      view.restore("http://h.test", "GET /x HTTP/1.1\nHost: h.test\n", false, true)

      String.new(view.request_bytes).should eq("GET /x HTTP/1.1\r\nHost: h.test\r\n\r\n")
    end

    it "leaves a request that already has a body alone" do
      view = RepeaterView.new
      view.restore("http://h.test", "POST /x HTTP/1.1\nHost: h.test\nContent-Length: 2\n\nhi", false, true)

      String.new(view.request_bytes).should end_with("\r\n\r\nhi")
    end

    # RFC 2046 §5.1.1: parts are delimited by CRLF + boundary. A bare-LF multipart body is
    # unparseable, and auto-CL re-frames it to the shortened length so nothing even hangs.
    it "restores CRLF delimiters in a multipart body" do
      view = RepeaterView.new
      view.restore("http://h.test",
        "POST /u HTTP/1.1\nHost: h.test\nContent-Type: multipart/form-data; boundary=B\nContent-Length: 9\n\n--B\nContent-Disposition: form-data; name=\"f\"\n\nhi\n--B--\n",
        false, true)

      sent = String.new(view.request_bytes)
      body = sent.split("\r\n\r\n", limit: 2)[1]
      body.should eq("--B\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nhi\r\n--B--\r\n")
      # Auto-CL frames the body it actually sends, not the pre-normalization one.
      sent.should contain("Content-Length: #{body.bytesize}")
    end

    # The head-only CRLF rule exists to protect bodies where 0x0A is a BYTE, not a line
    # ending. Only multipart opts out of it.
    it "leaves a non-multipart body's bare LFs alone" do
      view = RepeaterView.new
      view.restore("http://h.test",
        "POST /x HTTP/1.1\nHost: h.test\nContent-Type: application/json\nContent-Length: 9\n\n{\n\"a\":1\n}",
        false, true)

      String.new(view.request_bytes).should end_with("\r\n\r\n{\n\"a\":1\n}")
    end

    it "downgrades an HTTP/2 request line before an h1 send" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET /x HTTP/2\nHost: h.test\n\n", false, true)

      view.downgrade_h2_request_lines(group: false).should be_true
      view.request_text.lines.first.should eq("GET /x HTTP/1.1") # display agrees with the wire
      String.new(view.request_bytes).should start_with("GET /x HTTP/1.1\r\n")
    end

    # Narrow on purpose: this runs unasked on every send, so a version the operator meant
    # must survive it. Only a version h1 CANNOT carry is rewritten.
    it "leaves a deliberate version alone" do
      ["GET /x HTTP/1.0", "GET /x HTTP/9.9", "GET /x", "GET /x FTP/1.1"].each do |line|
        view = RepeaterView.new
        view.restore("https://h.test", "#{line}\nHost: h.test\n\n", false, true)

        view.downgrade_h2_request_lines(group: false).should be_false
        view.request_text.lines.first.should eq(line)
      end
    end

    it "never rewrites while the tab is on h2 — that request line is correct" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET /x HTTP/2\nHost: h.test\n\n", true, true)

      view.downgrade_h2_request_lines(group: false).should be_false
      view.request_text.lines.first.should eq("GET /x HTTP/2")
    end

    # A `%%%` means "next request" only for a send group. For a single ^R the whole buffer
    # is ONE request, so the lines under it are body text and must not be touched.
    it "downgrades every chunk of a send group, but only the first line of a single send" do
      text = "GET /a HTTP/2\nHost: h.test\n\n%%%\nGET /b HTTP/2\nHost: h.test\n"

      grouped = RepeaterView.new
      grouped.restore("https://h.test", text, false, true)
      grouped.downgrade_h2_request_lines(group: true).should be_true
      grouped.request_text.should_not contain("HTTP/2")

      single = RepeaterView.new
      single.restore("https://h.test", text, false, true)
      single.downgrade_h2_request_lines(group: false).should be_true
      single.request_text.lines.first.should eq("GET /a HTTP/1.1")
      single.request_text.should contain("GET /b HTTP/2") # body text — left alone
    end
  end

  describe "pretty_print_request" do
    it "pretty-prints JSON request body in-place and preserves markers" do
      view = RepeaterView.new
      view.restore("https://api.test", "POST /x HTTP/1.1\nHost: api.test\nContent-Type: application/json\nContent-Length: 30\n\n{\"a\":\"§val§\",\"b\":[1,2]}", false, true)

      view.pretty_print_request.should be_nil # success
      view.request_text.should contain("\"a\": \"§val§\"")
      view.request_text.should contain("  \"b\": [\n    1,\n    2\n  ]")
      view.dirty?.should be_true
      view.request_text.should_not contain("Content-Length: 30")
    end
  end

  # The single-pane REQUEST column, through the shared hit-test seam
  # (`request_hit`/`request_sub_rect`/`place_request_caret`) the split panes now share. There
  # was no drag or double-click coverage anywhere in the suite before, so the seam's
  # rewrite had nothing pinning the case it was factored out of.
  describe "mouse drag + double-click (plain HTTP request pane)" do
    head = "GET /alpha/beta HTTP/1.1\nHost: h.test\nUser-Agent: gori\n\n"

    rendered = -> {
      view = RepeaterView.new
      view.restore("https://h.test", head, false, true)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 100, 24)
      b = MemoryBackend.new(100, 24)
      view.render(Screen.new(b), rect) # geometry: @last_cw / last_rows are set here
      {view, b, rect}
    }

    # The request card sits under the 3-row TARGET band, in the left half, inset by its border.
    body_y = 4

    it "extends a READ-mode selection along the request line" do
      view, b, rect = rendered.call
      x0 = b.row(body_y).index("GET").not_nil!
      view.request_click_to_cursor(rect, x0, body_y)
      view.request_drag_to_cursor(rect, x0 + 3, body_y)
      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("GET")
    end

    it "extends an INSERT-mode selection through the editor's own anchor" do
      view, b, rect = rendered.call
      x0 = b.row(body_y).index("GET").not_nil!
      view.enter_request_insert!
      view.request_click_to_cursor(rect, x0, body_y)
      view.request_drag_to_cursor(rect, x0 + 3, body_y)
      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("GET")
    end

    # `word_char?` breaks a path at every `/`, so double-clicking inside "beta" takes the
    # segment and not the whole target.
    it "takes the word under a double-click" do
      view, b, rect = rendered.call
      x = b.row(body_y).index("beta").not_nil! + 1
      view.request_click_to_cursor(rect, x, body_y)
      view.request_select_word.should be_true
      view.pane_copy_text.should eq("beta")
    end

    # Hex has a nibble cursor, which has no selection to extend — the one request shape still
    # excluded from the drag.
    it "leaves the hex nibble cursor alone on a drag" do
      view, b, rect = rendered.call
      view.toggle_request_hex.should be_true
      view.request_drag_to_cursor(rect, b.row(body_y).size - 1, body_y) # must not raise
      view.pane_selection?.should be_false
    end
  end
end

describe "RepeaterView WebSocket frame shapes (V7)" do
  ws_head = "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n"

  # The pane is one message per LINE. Until V7 the only thing it could not render was a
  # binary payload; now a PING, a PONG, a CLOSE with a code, an RSV1 frame, a cleared FIN, a
  # pinned mask key and a declared length that disagrees with the payload are all capturable
  # — and every one of them would render as an ORDINARY line of text, so writing the pane
  # back would silently discard exactly the shape the operator captured it for. Showing it
  # and then losing it is worse than not showing it: the seed replays it verbatim.
  it "keeps a shaped or control frame OUT of the pane and IN the seed" do
    view = RepeaterView.new
    shape = Gori::Store::WsShape
    view.restore("https://ws.test", ws_head, false, true, ws_messages: [
      Gori::Store::WsOutMessage.text("plain"),
      Gori::Store::WsOutMessage.new(9, "ping".to_slice),
      Gori::Store::WsOutMessage.new(1, "rsv".to_slice, shape.new(rsv: 4)),
      Gori::Store::WsOutMessage.new(8, Bytes[0x03, 0xEA]),
      Gori::Store::WsOutMessage.text("also-plain"),
    ])
    # Only the two plain TEXT frames are lines the operator can edit …
    view.ws_out_messages_raw.size.should eq(5)
    # … and an untouched pane replays all five, shapes intact.
    view.ws_out_messages.map(&.opcode).should eq([1, 9, 1, 8, 1])
    view.ws_out_messages[2].shape.rsv.should eq(4)
  end

  # An empty (or short) pane with frames still in the seed is exactly the situation where an
  # operator misreads a result: they see nothing and a PING, a CLOSE 1002 and an RSV1 frame
  # go out anyway. The MESSAGES border badge and the open-from-History status line read this.
  it "names the seeded frames the pane is not showing" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: [
      Gori::Store::WsOutMessage.text("plain"),
      Gori::Store::WsOutMessage.new(9, "ping".to_slice),
      Gori::Store::WsOutMessage.new(1, "r".to_slice, Gori::Store::WsShape.new(rsv: 4)),
      Gori::Store::WsOutMessage.new(1, "u".to_slice, Gori::Store::WsShape.new(masked: false)),
      Gori::Store::WsOutMessage.new(8, Bytes[0x03, 0xEA] + "bye".to_slice),
    ])
    view.ws_unshown_seed.should eq(["PING", "TEXT rsv=4", "TEXT unmasked", "CLOSE"])
  end

  it "says nothing when every seeded frame IS a plain line" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true,
      ws_messages: ["a", "b"].map { |t| Gori::Store::WsOutMessage.text(t) })
    view.ws_unshown_seed.should be_empty
  end

  it "persists and reconciles the Sec-WebSocket-Key toggle" do
    # Off is the default and stays it: a replayed handshake reusing a captured key looks to a
    # server exactly like the replay a repeater guard watches for. But the editor SHOWS a key
    # line gori was silently dropping and re-appending, so the key on the wire was never the
    # key in the pane.
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: [] of Gori::Store::WsOutMessage)
    view.ws_keep_key?.should be_false
    view.toggle_ws_keep_key.should be_true
    view.ws_keep_key?.should be_true
    view.dirty?.should be_true
    # It is part of the request side, so a peer that flips it must not be skipped by the
    # reconcile poll's "nothing changed" test.
    view.request_side_matches?("https://ws.test", ws_head, false, true, nil, false).should be_false
    view.request_side_matches?("https://ws.test", ws_head, false, true, nil, true).should be_true
  end

  it "refuses the toggle outside WebSocket mode rather than storing a meaningless flag" do
    view = RepeaterView.new
    view.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
    view.ws_mode?.should be_false
    view.toggle_ws_keep_key.should be_false
    view.ws_keep_key?.should be_false
  end
end
