require "../../spec_helper"

# #1075: `repeater create` took a request whose head never terminates (`\r\n\r` — one byte
# short), reported `created successfully`, stored it verbatim, and every later `repeater send`
# put the malformed message on the wire with the origin's bare `400` as the only feedback.
#
# The fix is NOT a refusal and NOT a repair. gori must stay able to send non-standard HTTP —
# an unterminated head is a desync/slowloris primitive and the repeater is where it belongs —
# so the whole change is that the malformation stops being invisible. These are the two pure
# pieces every surface reads: the predicate, and the one sentence they all say.
describe "an unterminated request head" do
  describe "Gori::Env.head_terminated?" do
    it "accepts each of the three terminator spellings the send path accepts" do
      Gori::Env.head_terminated?("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice).should be_true
      Gori::Env.head_terminated?("GET / HTTP/1.1\nHost: h\n\n".to_slice).should be_true
      # A bare-LF header terminator followed by a CRLF blank line — the shape
      # `head_body_separator` grew its middle branch for.
      Gori::Env.head_terminated?("GET / HTTP/1.1\nHost: h\n\r\n".to_slice).should be_true
    end

    # The repro from the issue, byte for byte: shell `$(…)` strips trailing newlines, so a
    # terminator typed as `\r\n\r\n` arrives as `\r\n\r`.
    it "rejects the head that is one byte short of terminating" do
      Gori::Env.head_terminated?("GET /x HTTP/1.1\r\nHost: h\r\nAccept: */*\r\n\r".to_slice)
        .should be_false
    end

    it "rejects a head with no blank line at all, and one with no line ending at all" do
      Gori::Env.head_terminated?("GET / HTTP/1.1\r\nHost: h\r\n".to_slice).should be_false
      Gori::Env.head_terminated?("GET / HTTP/1.1".to_slice).should be_false
    end

    # The half that explains why a two-tab workflow breaks asymmetrically: a request WITH a
    # body survives the same truncation, because the body follows the terminator. So the POST
    # tab works and the GET tab beside it silently does not.
    it "accepts a terminated head whose body was itself truncated" do
      Gori::Env.head_terminated?("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\nab".to_slice)
        .should be_true
    end

    # It has to keep asking `head_body_separator`, because that is what the send path asks:
    # a marker computed from a second scanner would eventually disagree with the socket.
    it "answers exactly what the send path's boundary scan answers" do
      bytes = "GET /x HTTP/1.1\r\nHost: h\r\n\r".to_slice
      Gori::Env.head_terminated?(bytes).should be_false
      # "no separator" reads as "all head" there — which is precisely why nothing downstream
      # ever noticed, and why the notice has to come from here.
      Gori::Env.head_body_boundary(bytes).should eq(bytes.size)
    end
  end

  describe "Gori::CLI::Run.unterminated_head?" do
    terminated = "GET /x HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
    truncated = "GET /x HTTP/1.1\r\nHost: h\r\n\r".to_slice
    ws = "GET /chat HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r".to_slice

    it "says nothing about a well-formed row" do
      Gori::CLI::Run.unterminated_head?(terminated, ws_http_only: false, http2: false).should be_false
      Gori::CLI::Run.unterminated_head?(terminated, ws_http_only: true, http2: false).should be_false
    end

    it "flags a stored request whose head never terminates" do
      Gori::CLI::Run.unterminated_head?(truncated, ws_http_only: false, http2: false).should be_true
    end

    # A blank-line terminator is an HTTP/1.1 wire fact. `H2Engine.parse_request` turns this
    # text into an HPACK field list in which the missing line was never represented, so an h2
    # session sends a well-formed request either way — the example below proves that rather
    # than asserting it — and a permanent `!head-unterminated` on such a tab would be a lie.
    it "exempts an HTTP/2 session, whose wire has no head terminator at all" do
      Gori::CLI::Run.unterminated_head?(truncated, ws_http_only: false, http2: true).should be_false
    end

    it "sends the same h2 fields whether or not the head terminates" do
      whole, _ = Gori::Repeater::H2Engine.parse_request(terminated, "https", "h", 443)
      short, _ = Gori::Repeater::H2Engine.parse_request(truncated, "https", "h", 443)
      short.should eq(whole)
    end

    # `WsEngine.build_handshake` re-emits the head line by line and writes its own `\r\n`
    # terminator, so a framed handshake is framed on the wire whatever the row holds. Flagging
    # one would accuse gori of sending bytes it does not send.
    it "exempts a handshake that will go out through WsEngine" do
      Gori::CLI::Run.unterminated_head?(ws, ws_http_only: false, http2: false).should be_false
    end

    # …but `ws_http_only` opts that session OUT of the framed engine: those bytes go through
    # the HTTP engine untouched, so they are back in.
    it "does not exempt the same handshake when the session is sent as plain HTTP" do
      Gori::CLI::Run.unterminated_head?(ws, ws_http_only: true, http2: false).should be_true
    end
  end

  # The short spelling the TUI toast appends. It exists because the full sentence would push
  # the status, the duration and two other clauses off a narrow terminal — but it is a method
  # beside the sentence, not a literal at the call site, so the two cannot drift.
  describe "Gori::CLI::Run.unterminated_head_chip" do
    it "keeps the two halves that may not be dropped: what is wrong, and that gori sent it" do
      chip = Gori::CLI::Run.unterminated_head_chip
      chip.should contain("NOT terminated")
      chip.should contain("sent as given")
      chip.size.should be < 60
    end
  end

  describe "Gori::CLI::Run.unterminated_head_note" do
    note = Gori::CLI::Run.unterminated_head_note

    # The wording carries the DESIGN decision, not just the fact. If a later edit turns this
    # sentence into a refusal ("pass --force", "refused"), the intent it documents — gori
    # sends non-standard HTTP — has been given up somewhere else too.
    it "states that gori sent the bytes as given rather than refusing or repairing them" do
      note.should contain("never repairs")
      note.should_not contain("refus")
    end

    it "names the missing blank line and the shell substitution that eats it" do
      note.should contain("blank line")
      note.should contain("$(")
    end
  end
end
