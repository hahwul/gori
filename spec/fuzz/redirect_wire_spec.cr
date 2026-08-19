require "../spec_helper"

private alias F = Gori::Fuzz

# The bytes the fuzzer's redirect follower actually puts on a socket (#397).
#
# A spec that asserted on the resolved path STRING would prove nothing here — that was #390's
# lesson. Every layer between the `Location` header and the request line preserves a raw SP or
# TAB happily (the response codec strips only the OWS around a field-value, and `URI.parse`
# validates neither `path` nor `query`), so the forged request line stays invisible until it is
# assembled. These examples read it back off a real TCP connection instead, and COUNT request
# lines rather than parsing the first one.

# A recording origin. Answers each connection with the next canned response (repeating the last
# once they run out, with `{PORT}` substituted so a response can name the listener itself) and
# returns the raw bytes of every connection it accepted, in order.
private def wire_of(responses : Array(String), &) : Array(String)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = [] of String
  spawn do
    hop = 0
    while conn = server.accept?
      slice = Bytes.new(16384)
      n = 0
      begin
        # One read, then answer: the sender is blocked waiting on a response, so reading to
        # EOF here would deadlock. A splice rides in the SAME write as the request it hangs
        # off (the follower emits a single slice), so one read sees all of it.
        conn.read_timeout = 500.milliseconds
        n = conn.read(slice)
      rescue IO::Error
      end
      # Recorded BEFORE the response is written, so every connection the engine has finished
      # with is already in `seen` by the time `run` returns.
      seen << String.new(slice[0, n])
      begin
        # `last?`, not `last`: an empty `responses` would otherwise raise IndexError here, which
        # is neither of the rescued IO errors — the recording fiber would die and every
        # assertion below would read an empty wire as "nothing was sent".
        conn << (responses[hop]? || responses.last? || OK_RESPONSE).gsub("{PORT}", port)
        conn.flush
      rescue IO::Error
      end
      hop += 1
      conn.close rescue nil
    end
  rescue IO::Error
  end

  yield port
  server.close rescue nil
  seen
end

# Every request line across every connection of the run. The whole point of this class of bug is
# that there can be more of them than the engine believes it sent, so this counts.
#
# Two details are load-bearing, and getting either wrong makes this silently blind to the very
# bug it exists to catch. Lines are split on a bare LF as well as CRLF, because that is how a
# poisoned Location reaches the wire (see the bare-LF example below) and because an LF-lenient
# origin breaks lines on either (RFC 7230 §3.5). And the target is matched with `.+`, not `\S+`:
# a forged line has FOUR or more tokens (`GET /a b HTTP/1.1 HTTP/1.1`), so `\S+` would refuse to
# match it and quietly drop it from the count.
private def request_lines(wire : Array(String)) : Array(String)
  wire.flat_map(&.split(/\r\n|\n/)).select(&.matches?(/\A[A-Z]+ .+ HTTP\/\d(?:\.\d)?\z/))
end

private def redirect_to(location : String) : String
  "HTTP/1.1 302 Found\r\nLocation: #{location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
end

private OK_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"

# Drives one single-payload run against `port` with redirect following on, and hands the results
# back so an example can also assert what the operator is shown.
private def run_fuzz(port : Int32) : Array(F::Result)
  tmpl = F::Template.parse("GET /start?q=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
  set = F::PayloadSet.new(F::InlineList.new(["one"]))
  cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, follow_redirects: true,
    max_redirects: 3, timeout: 2.seconds)
  gen = F::Generator.new(tmpl, [set], cfg)
  backend = F::Sender.new(F::Origin.new("http", "127.0.0.1", port), ungated_outbound,
    http2: false, verify: false)
  results = [] of F::Result
  F::Engine.new(gen, F::Matcher.new, backend, cfg).run do |ev|
    results << ev.result if ev.is_a?(F::ResultEvent)
  end
  results
end

describe "Fuzz::Engine redirect following" do
  # The control. Without it every assertion below would pass just as happily against a harness
  # that never observes the socket, or against an engine that stopped following redirects at all.
  it "follows a clean same-origin Location, one request per hop" do
    wire = wire_of([redirect_to("/next?ok=1"), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq([
      "GET /start?q=one HTTP/1.1",
      "GET /next?ok=1 HTTP/1.1",
    ])
    wire[1].should match(/\AGET \/next\?ok=1 HTTP\/1\.1\r\nHost: 127\.0\.0\.1:\d+\r\nConnection: close\r\n\r\n\z/)
  end

  it "does not follow a Location carrying a raw space (request-line forgery)" do
    # The exact shape #397 recorded: `Location: /a b HTTP/1.1` survives the response codec
    # verbatim, and interpolating it produced `GET /a b HTTP/1.1 HTTP/1.1` — which a lenient
    # origin reads as target `/a`, version `b`. gori would then record and report a hit on a
    # resource it never actually asked for.
    wire = wire_of([redirect_to("/a b HTTP/1.1"), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq(["GET /start?q=one HTTP/1.1"])
    wire.size.should eq(1) # the second hop is never dialled at all
    wire.join.should_not contain("/a b")
  end

  it "does not follow a Location carrying a raw tab" do
    wire = wire_of([redirect_to("/a\tb"), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq(["GET /start?q=one HTTP/1.1"])
    wire.size.should eq(1)
    wire.join.should_not contain("/a\tb")
  end

  it "applies the same rule to an absolute-form same-origin Location" do
    # `URI.parse("http://127.0.0.1:PORT/a b").path` is `"/a b"` just as verbatim, and that
    # branch of resolve_redirect_path reaches the request line through the same assembler — so
    # a guard wired only into the relative branch would leave this half open.
    wire = wire_of([redirect_to("http://127.0.0.1:{PORT}/a b"), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq(["GET /start?q=one HTTP/1.1"])
    wire.size.should eq(1)
    wire.join.should_not contain("/a b")
  end

  it "still follows an absolute-form same-origin Location that is clean" do
    # The control for the example above: the absolute-form branch is refused for the byte, not
    # because absolute-form stopped working.
    wire = wire_of([redirect_to("http://127.0.0.1:{PORT}/next"), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq([
      "GET /start?q=one HTTP/1.1",
      "GET /next HTTP/1.1",
    ])
  end

  # The third form of a `Location`, and the one that slipped past the same-origin comparison
  # entirely. A scheme-relative `//evil.test/x` (RFC 3986 §4.2 network-path reference) names
  # ANOTHER host, but `resolve_redirect_path` returned it verbatim because it starts with `/`,
  # so it never reached the cross-origin check — and the follower asked the ORIGIN for the
  # literal path `//evil.test/x`, burning a hop and replacing the 302 an open-redirect probe is
  # hunting with whatever that path answers.
  it "does not follow a scheme-relative cross-origin Location" do
    results = [] of F::Result
    wire = wire_of([redirect_to("//evil.test/x"), OK_RESPONSE]) { |port| results = run_fuzz(port) }

    request_lines(wire).should eq(["GET /start?q=one HTTP/1.1"])
    wire.size.should eq(1)
    wire.join.should_not contain("evil.test")
    # The 302 is the finding; it has to survive to the operator's row.
    results.size.should eq(1)
    results[0].status.should eq(302)
    results[0].error.should be_nil
  end

  it "still follows a scheme-relative SAME-origin Location, resolved to a path" do
    # The discriminator: refusing every `//` outright would break this, and asserting only the
    # hop COUNT would pass at HEAD (which does send a second request — for the literal path
    # `//127.0.0.1:PORT/next`). The exact request line is what pins the resolution.
    wire = wire_of([redirect_to("//127.0.0.1:{PORT}/next"), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq([
      "GET /start?q=one HTTP/1.1",
      "GET /next HTTP/1.1",
    ])
  end

  it "reports the refused 3xx rather than dropping or erroring the row" do
    results = [] of F::Result
    wire = wire_of([redirect_to("/a b"), OK_RESPONSE]) { |port| results = run_fuzz(port) }

    request_lines(wire).size.should eq(1)
    # Refusing to follow leaves the operator with the redirect the origin actually sent, exactly
    # like the existing cross-origin behaviour — not a dropped row and not a fabricated error.
    results.size.should eq(1)
    results[0].status.should eq(302)
    results[0].error.should be_nil
  end

  # The splicing half of the class, and the reason this is more than a correctness bug.
  #
  # #397 recorded that CR/LF "is not reachable here — the response head is split on line
  # terminators before Location is read". That is not so, and it is worth pinning as a test
  # rather than a comment. `index_crlf`/`parse_headers` break header lines on the TWO-BYTE CRLF
  # only, and a field-value is stripped at its ends, so a BARE LF or bare CR sits in the parsed
  # `Location` verbatim. `obfuscated_header?` would catch it, but the RESPONSE path deliberately
  # gates on the narrower `framing_ambiguous?` instead, so that a legacy origin does not 502.
  #
  # That narrowness is what leaves this reachable. A poisoned `Location` IS refused before the
  # follower when its smuggled lines change how the response frames — a blank line, or a
  # `Content-Length:` line, makes the strict and lenient views disagree and `Repeater::Engine`
  # errors. Neither is needed to forge a request: the payload below carries only an ordinary
  # request line, both views agree, the read succeeds, and pre-fix those bytes went on the wire.
  it "does not follow a Location carrying a bare LF (request splicing)" do
    poisoned = "/a\nGET http://evil.test/pwned HTTP/1.1\nHost: evil.test"
    wire = wire_of([redirect_to(poisoned), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq(["GET /start?q=one HTTP/1.1"])
    wire.size.should eq(1)
    wire.join.should_not contain("evil.test")
  end

  it "does not follow a Location carrying a bare CR" do
    # The mirror image, reachable for the same reason: a lone CR never terminates a header line
    # for `index_crlf` either, so it too survives into the value.
    poisoned = "/a\rGET http://evil.test/pwned HTTP/1.1\rHost: evil.test"
    wire = wire_of([redirect_to(poisoned), OK_RESPONSE]) { |port| run_fuzz(port) }

    request_lines(wire).should eq(["GET /start?q=one HTTP/1.1"])
    wire.size.should eq(1)
    wire.join.should_not contain("evil.test")
  end
end
