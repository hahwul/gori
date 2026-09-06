require "../spec_helper"

# A request line gori cannot FRAME as "METHOD SP request-target SP HTTP-version" has no
# request-target to build a URL from — `parse_request_line`'s `parts[1]` is some OTHER token.
# `Gori::FlowMapper` already refuses to STORE a derived target for these lines ("History would
# render a deceptively-plausible-but-wrong URL") and keeps the verbatim line instead; the export
# surface re-parsed the raw head and produced exactly that URL, RUNNABLE.
#
# These pin the OBSERVABLE outputs — what `Curl.text` returns, what `RequestParts.from_wire`
# hands the five code serializers, and what the TUI's copy menu offers — not the predicate on
# its own, which `Curl.text` could stop calling without failing a single example.
#
# The negative cases carry as much weight as the positive ones: a 3-token line whose TARGET
# holds a tab frames cleanly and is the operator's payload (DESIGN.md §7), and `GET /p` is the
# hand-authored Repeater line `parse_request_line`'s tolerance exists for. Over-refusing either
# is the regression this guards against.
private SPACE_IN_TARGET = "GET http://h.test/echo?a=b c&d=e HTTP/1.1\r\nHost: h.test\r\n\r\n"
private DOUBLED_SPACE   = "GET  http://h.test/admin HTTP/1.1\r\nHost: h.test\r\n\r\n"
private TAB_DELIMITED   = "GET\thttp://h.test/admin HTTP/1.1\r\nHost: h.test\r\n\r\n"
private TAB_IN_TARGET   = "GET /a\tb HTTP/1.1\r\nHost: h.test\r\n\r\n"
private NO_VERSION      = "GET /p\r\nHost: h.test\r\n\r\n"

describe "an unframable request line" do
  describe "Gori::Export::Curl.text" do
    it "hands back a `# no command` comment instead of a URL guessed off the wrong token" do
      {SPACE_IN_TARGET, DOUBLED_SPACE, TAB_DELIMITED}.each do |wire|
        out = Gori::Export::Curl.text(wire, "http://h.test").not_nil!
        out.should start_with("# no command:")
        out.should contain("Read the request line with --format raw")
        # The whole point: nothing runnable, and specifically not the plausible URL the naive
        # `parts[1]` parse produced — `?a=b` for the first, the bare origin for the second,
        # `/HTTP/1.1` (a resource nobody requested) for the third.
        out.should_not contain("curl '")
      end
    end

    it "names WHICH framing failure it is, so the sentence is not one message for two bugs" do
      Gori::Export::Curl.text(DOUBLED_SPACE, "http://h.test").not_nil!
        .should contain("splits into 4 space-separated tokens")
      Gori::Export::Curl.text(TAB_DELIMITED, "http://h.test").not_nil!
        .should contain("a TAB stands where a space delimiter belongs")
    end

    it "still exports a 3-token line whose TARGET holds a tab — that tab is the payload" do
      out = Gori::Export::Curl.text(TAB_IN_TARGET, "http://h.test").not_nil!
      out.should start_with("curl 'http://h.test/a")
      out.should_not contain("no command")
    end

    it "still exports a hand-authored line with no version — `GET /p` frames cleanly" do
      out = Gori::Export::Curl.text(NO_VERSION, "http://h.test").not_nil!
      out.should contain("curl 'http://h.test/p'")
      out.should_not contain("no command")
    end
  end

  describe "Gori::Export::RequestParts.from_wire" do
    it "refuses, so all five code serializers refuse with it rather than each guarding" do
      {SPACE_IN_TARGET, DOUBLED_SPACE, TAB_DELIMITED}.each do |wire|
        Gori::Export::RequestParts.from_wire(wire, "http://h.test").should be_nil
      end
    end

    it "keeps parsing the lines that DO frame" do
      {TAB_IN_TARGET, NO_VERSION}.each do |wire|
        Gori::Export::RequestParts.from_wire(wire, "http://h.test").should_not be_nil
      end
    end
  end

  describe "Gori::Tui::CopyMenu.request_options" do
    it "drops every row derived from the guessed URL, and keeps the byte-exact ones" do
      opts = Gori::Tui::CopyMenu.request_options(DOUBLED_SPACE, "http://h.test")
      labels = opts.map(&.label)
      # URL and the four language rows are all built from the token that is not the target.
      labels.should_not contain("URL")
      labels.should_not contain("Python")
      labels.should_not contain("fetch")
      labels.should_not contain("Go")
      labels.should_not contain("httpie")
      labels.should_not contain("CSRF PoC")
      # The bytes gori actually captured are still copyable — the refusal is about DERIVED text.
      labels.should contain("Raw request")
      labels.should contain("Headers")
    end

    it "keeps the cURL row so the clipboard carries the reason, not silence" do
      opts = Gori::Tui::CopyMenu.request_options(DOUBLED_SPACE, "http://h.test")
      curl = opts.find { |o| o.label == "cURL" }.not_nil!
      curl.text.should start_with("# no command:")
    end

    it "offers the full menu for a line that frames" do
      labels = Gori::Tui::CopyMenu.request_options(TAB_IN_TARGET, "http://h.test").map(&.label)
      labels.should contain("URL")
      labels.should contain("cURL")
      labels.should contain("Python")
      labels.should contain("CSRF PoC")
    end
  end
end
