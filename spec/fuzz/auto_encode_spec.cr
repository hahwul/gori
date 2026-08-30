require "../spec_helper"

private alias F = Gori::Fuzz

# `--auto` found the position and left the encoding to the operator, so
# `gori run fuzz --auto --preset xss` spliced `<script>alert(1)</script>` into `?q=` raw:
# the space ends the request-target, the rest becomes the HTTP version token, and the
# origin answers 400 to a request that never carried the payload under test. Every
# playbook grew the footnote "add `--encode url`" — a default written in prose instead of
# in the code. `Fuzz::AutoEncode` moves it into the builder every surface goes through.
#
# Pinned at the WIRE, off `Generator#each`: the request bytes each candidate would send
# are the only statement that survives a refactor of where the encode is applied.

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# Every candidate request this option set would send, as strings.
private def wires(options : F::PlanOptions) : Array(String)
  plan = F::Plan.build(options, ungated)
  out = [] of String
  plan.generator.each { |j| out << String.new(j.bytes) }
  out
end

private def options(template : String, payloads : Array(String),
                    auto_mark : Bool = false, auto_encode : Bool = true,
                    processors : Array(F::Processor) = [] of F::Processor,
                    config : F::Config = F::Config.new) : F::PlanOptions
  F::PlanOptions.new(template, target: "http://t.test", auto_mark: auto_mark,
    sources: [F::InlineList.new(payloads).as(F::PayloadSource)],
    processors: processors, auto_encode: auto_encode, config: config,
    matcher: F::Matcher.new(keep_bodies: :none))
end

private QUERY = "GET /s?q=§hi§ HTTP/1.1\r\nHost: t.test\r\n\r\n"

private FORM = "POST /s HTTP/1.1\r\nHost: t.test\r\n" \
               "Content-Type: application/x-www-form-urlencoded\r\n" \
               "Content-Length: 5\r\n\r\nn=§jay§"

private JSON_BODY = "POST /s HTTP/1.1\r\nHost: t.test\r\nContent-Type: application/json\r\n" \
                    "Content-Length: 11\r\n\r\n{\"q\":\"§hi§\"}"

describe "fuzz auto URL-encoding" do
  it "percent-encodes a payload spliced into a query-string value" do
    wire = wires(options(QUERY, ["<script>"])).first
    wire.should contain("GET /s?q=%3Cscript%3E HTTP/1.1")
    wire.should_not contain("<script>")
  end

  it "percent-encodes a payload spliced into a form-urlencoded body value" do
    wire = wires(options(FORM, ["a b&x=1"])).first
    wire.should contain("n=a%20b%26x%3D1")
    wire.should_not contain("n=a b&x=1")
  end

  it "leaves a JSON body position raw" do
    wire = wires(options(JSON_BODY, ["<script>"])).first
    wire.should contain(%({"q":"<script>"}))
  end

  it "leaves a path segment, a header and a cookie value raw" do
    path = "GET /a/§seg§/b HTTP/1.1\r\nHost: t.test\r\n\r\n"
    wires(options(path, ["../../etc"])).first.should contain("GET /a/../../etc/b HTTP/1.1")

    header = "GET /a HTTP/1.1\r\nHost: t.test\r\nX-Try: §v§\r\n\r\n"
    wires(options(header, ["a b"])).first.should contain("X-Try: a b\r\n")

    cookie = "GET /a HTTP/1.1\r\nHost: t.test\r\nCookie: sid=§abc§\r\n\r\n"
    wires(options(cookie, ["x=1"])).first.should contain("Cookie: sid=x=1\r\n")
  end

  # `--auto` / MCP `auto:true` mark the head+body themselves; the TUI's `^A params` hands
  # `Plan.build` an ALREADY-marked template. Both roads must reach the same wire — the
  # classification is structural (`Template#urlencoded_positions`), not a flag the marker
  # sets, which is what makes that true by construction.
  it "reaches the same wire from --auto as from a pre-marked template" do
    raw = "POST /s?q=hi HTTP/1.1\r\nHost: t.test\r\nCookie: sid=abc\r\n" \
          "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\nn=jay"
    marked = "POST /s?q=§hi§ HTTP/1.1\r\nHost: t.test\r\nCookie: sid=§abc§\r\n" \
             "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\nn=§jay§"
    auto = wires(options(raw, ["<b>"], auto_mark: true))
    pre = wires(options(marked, ["<b>"]))
    auto.should eq pre
    # Sniper: one request per position, in position order — query, cookie, body.
    auto.size.should eq 3
    auto[0].should contain("?q=%3Cb%3E ")
    auto[1].should contain("Cookie: sid=<b>\r\n") # a cookie value is NOT percent-encoded
    auto[2].should end_with("n=%3Cb%3E")
  end

  # Sniper substitutes ONE position and leaves the rest at their template defaults. A
  # default is the capture's own bytes, already encoded as the site wrote them — encoding
  # it again would make every Sniper request a different base request than the marked one.
  it "never re-encodes the defaults of the positions it did not substitute" do
    tmpl = "GET /s?a=§x%20y§&b=§2§ HTTP/1.1\r\nHost: t.test\r\n\r\n"
    w = wires(options(tmpl, ["<b>"]))
    w.size.should eq 2
    w[0].should contain("?a=%3Cb%3E&b=2 ")
    w[1].should contain("?a=x%20y&b=%3Cb%3E ")
    w.none?(&.includes?("%2520")).should be_true
  end

  # BatteringRam/Pitchfork/ClusterBomb substitute EVERY position at once (Job#position is
  # nil), so every encoded position is encoded on the same request.
  it "encodes every substituted position when the mode has no single active one" do
    tmpl = "GET /s?a=§1§&b=§2§ HTTP/1.1\r\nHost: t.test\r\n\r\n"
    w = wires(options(tmpl, ["<b>"], config: F::Config.new(mode: F::Mode::BatteringRam)))
    w.size.should eq 1
    w[0].should contain("?a=%3Cb%3E&b=%3Cb%3E ")
  end

  it "leaves the query raw under --no-encode" do
    wire = wires(options(QUERY, ["<script>"], auto_encode: false)).first
    wire.should contain("GET /s?q=<script> HTTP/1.1")
  end

  # An explicit `--encode` is the operator saying how the wire should SPELL the payload. It
  # WINS and applies to every position — it is never stacked on top of the default, which
  # would double-encode the `%3C` it just produced.
  it "an explicit --encode url still applies, exactly once" do
    procs = [F::Encode.new(:url).as(F::Processor)]
    wires(options(QUERY, ["a b"], processors: procs)).first.should contain("?q=a%20b ")
    wires(options(QUERY, ["<script>"], processors: procs)).first
      .should contain("?q=%3Cscript%3E ")
    wires(options(QUERY, ["<script>"], processors: procs)).first
      .should_not contain("%253C")
    # ...and it still reaches the positions the default deliberately leaves alone.
    wires(options(JSON_BODY, ["a b"], processors: procs)).first.should contain(%({"q":"a%20b"}))
  end

  it "an explicit --encode base64 is not wrapped in a URL-encode" do
    procs = [F::Encode.new(:base64).as(F::Processor)]
    # `YWI=` — the trailing `=` proves nothing percent-encoded the base64 afterwards.
    wires(options(QUERY, ["ab"], processors: procs)).first.should contain("?q=YWI= ")
  end

  # …but the OTHER processors are not that statement, and the gate used to be
  # `processors.empty?`: one `--prefix` turned the default off for the whole run and put the
  # payload's own space on the request-target, where it ends the target and the origin reads
  # the parameter as `P<img` — the very failure this default exists to stop — while the row
  # still said `1 sent · 0 errors`.
  it "keeps the default under a --prefix / --case / --hash pipeline (no Encode in it)" do
    space = "<img src=x onerror=alert(1)>"
    encoded = "P%3Cimg%20src%3Dx%20onerror%3Dalert%281%29%3E"
    prefixed = [F::Prefix.new("P").as(F::Processor)]
    wire = wires(options(QUERY, [space], processors: prefixed)).first
    wire.should contain("GET /s?q=#{encoded} HTTP/1.1")
    wire.should_not contain("?q=P<img")
    # …and the pipeline still ran: the prefix is there, and it reaches the positions the
    # default leaves alone byte-verbatim.
    wires(options(JSON_BODY, [space], processors: prefixed)).first.should contain(%({"q":"P#{space}"}))
    # `--case` folds the payload, `--hash` replaces it with hex — neither says how the wire
    # spells it, so both keep the default too (over hex the encode is simply a no-op).
    folded = [F::Case.new(:upper).as(F::Processor)]
    wires(options(QUERY, ["a b"], processors: folded)).first.should contain("?q=A%20B ")
    hashed = [F::Hasher.new(:md5).as(F::Processor)]
    wires(options(QUERY, ["ab"], processors: hashed)).first
      .should contain("?q=187ef4436122d1cc2f40dc2b92f0eba0 ")
  end

  # An `Encode` ANYWHERE in the pipeline stands the default down, not only a last one:
  # `--encode url --suffix '&x=1'` has already produced the `%3C` this must not wrap.
  it "stands down for an Encode anywhere in the pipeline, not only the last step" do
    procs = [F::Encode.new(:url).as(F::Processor), F::Suffix.new("&x=1").as(F::Processor)]
    wire = wires(options(QUERY, ["<b>"], processors: procs)).first
    wire.should contain("?q=%3Cb%3E&x=1 ")
    wire.should_not contain("%253C")
    # …and the same for a base64 run carrying a prefix.
    mixed = [F::Prefix.new("v=").as(F::Processor), F::Encode.new(:base64).as(F::Processor)]
    wires(options(QUERY, ["ab"], processors: mixed)).first.should contain("?q=dj1hYg== ")
  end

  # A per-position `§value¦chain§` is the same statement aimed at one position, so that
  # position opts out on its own while its neighbours keep the default.
  it "a position carrying its own ¦chain opts out, its neighbours do not" do
    tmpl = "GET /s?a=§x¦base64§&b=§y§ HTTP/1.1\r\nHost: t.test\r\n\r\n"
    w = wires(options(tmpl, ["ab"], config: F::Config.new(mode: F::Mode::BatteringRam)))
    w.first.should contain("?a=YWI=&b=ab ")
  end

  it "resyncs Content-Length to the ENCODED body" do
    wire = wires(options(FORM, ["<b>"])).first
    wire.should contain("n=%3Cb%3E")
    wire.should contain("Content-Length: #{"n=%3Cb%3E".bytesize}\r\n")
  end
  # The documented cost of the default, pinned so a future "skip encoding when the payload
  # already looks encoded" shortcut has to come and delete this example on purpose.
  #
  # `%` is a reserved byte like any other, so an ALREADY-encoded payload is encoded again. For a
  # probe whose target is the origin's own decoder that is destructive rather than merely
  # different: `%00` reaches the app as three characters, never a NUL, and `%c0%af` (the
  # overlong-UTF-8 `/`) as text no normalizer folds. `%2e%2e%2f` only shifts single-decode to
  # double-decode. Six surfaces say so — see `AutoEncode`'s header for the list — and this is
  # the one that fails if the behaviour moves without them.
  it "encodes an ALREADY-encoded payload again, which is why --no-encode exists" do
    ae = F::AutoEncode.build(F::Template.parse(QUERY), [] of F::Processor, true)
    ae.apply(["%00"], nil).should eq ["%2500"]
    ae.apply(["%c0%af"], nil).should eq ["%25c0%25af"]
    ae.apply(["..%2f..%2fetc%2fpasswd"], nil).should eq ["..%252f..%252fetc%252fpasswd"]
    # …and `no_encode` / `--no-encode` is the documented way out: the payload passes through
    # byte-for-byte, as the SAME array object.
    raw = ["%00"]
    off = F::AutoEncode.build(F::Template.parse(QUERY), [] of F::Processor, false)
    off.apply(raw, nil).should be(raw)
  end
end

describe Gori::Fuzz::Template do
  it "classifies which positions sit in a percent-encoded region" do
    F::Template.parse(QUERY).urlencoded_positions.should eq [0]
    F::Template.parse(FORM).urlencoded_positions.should eq [0]
    F::Template.parse(JSON_BODY).urlencoded_positions.should be_empty
    # A body with no content-type that looks like a form is treated as one — the same
    # predicate `auto_mark` uses to decide it should mark those values at all.
    typeless = "POST /s HTTP/1.1\r\nHost: t.test\r\nContent-Length: 5\r\n\r\nn=§jay§"
    F::Template.parse(typeless).urlencoded_positions.should eq [0]
    # Query AND form in one request, with a path and cookie position between them.
    both = "POST /a/§seg§?q=§hi§ HTTP/1.1\r\nHost: t.test\r\nCookie: sid=§abc§\r\n" \
           "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\nn=§jay§"
    F::Template.parse(both).urlencoded_positions.should eq [1, 3]
  end

  # A capture's body may legitimately not be valid UTF-8 (a protobuf frame, a gzip'd POST).
  # The classifier is a BYTE scan for that reason — it must not walk the body as chars, and
  # must not change the bytes it was asked about.
  it "classifies a template whose body is not valid UTF-8 without touching it" do
    body = String.new(Bytes[0x6E, 0x3D, 0xFF, 0xFE, 0x01, 0x02])
    tmpl = F::Template.parse("GET /s?q=§hi§ HTTP/1.1\r\nHost: t.test\r\n\r\n#{body}")
    tmpl.urlencoded_positions.should eq [0]
    String.new(tmpl.render(["hi"])).should end_with(body)
  end
end
