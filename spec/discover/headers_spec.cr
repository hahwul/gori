require "../spec_helper"

private alias H = Gori::Discover::Headers

describe Gori::Discover::Headers do
  describe ".parse_lines" do
    it "parses Name: Value lines and strips whitespace" do
      H.parse_lines(["Authorization: Bearer t", "X-Env:  staging  "]).should eq(
        [{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    end

    it "keeps colons in the value (splits on the first one only)" do
      H.parse_lines(["X-Time: 10:30:00"]).should eq([{"X-Time", "10:30:00"}])
    end

    it "drops lines without a colon, an empty name, or an illegal token name" do
      H.parse_lines(["nope", ": value", "Bad Name: v", "X-Ok: y"]).should eq([{"X-Ok", "y"}])
    end

    it "drops non-ASCII and separator-bearing field names" do
      H.parse_lines(["X-Заголовок: v", "Bad/Name: v", "X-Ok: y"]).should eq([{"X-Ok", "y"}])
    end

    it "drops a value carrying CR/LF (header-injection guard)" do
      H.parse_lines(["X-Inject: a\r\nEvil: y"]).should be_empty
    end

    # Refusing is right; refusing SILENTLY is not. The header this drops is `Authorization`,
    # and the crawl then ran unauthenticated and reported "found nothing" over the whole
    # authenticated surface — clean exit, nothing on stderr, and no way to tell that case from
    # a genuinely empty target except by sniffing. The count of drops was not returned, so no
    # caller COULD report it.
    it "reports every rejected line through the out-collector, verbatim" do
      rejected = [] of String
      H.parse_lines(["nope", "X-Ok: y", "Bad Name: v", "X-Inject: a\r\nEvil: y"], rejected)
        .should eq([{"X-Ok", "y"}])
      rejected.should eq(["nope", "Bad Name: v", "X-Inject: a\r\nEvil: y"])
    end

    # A blank line is not a header anyone asked for — the TUI overlay parses an editor
    # buffer, which is full of them — so it is neither parsed nor reported.
    it "ignores blank lines entirely rather than reporting them as rejects" do
      rejected = [] of String
      H.parse_lines(["", "   ", "X-Ok: y"], rejected).should eq([{"X-Ok", "y"}])
      rejected.should be_empty
    end

    it "leaves the collector empty when every line is fine (the complement)" do
      rejected = [] of String
      H.parse_lines(["Authorization: Bearer t", "X-Time: 10:30:00"], rejected).size.should eq(2)
      rejected.should be_empty
    end
  end

  # The realistic half of the same failure: the line the operator typed is fine and the ENV
  # VAR is not — a token read from a file that kept its trailing newline. `expand` still drops
  # such a value at send time (it must: it is the last look before the wire), but a backstop
  # that fires silently on every probe is not a report, and by then the crawl is running. This
  # is the QUERY a surface asks BEFORE any traffic.
  describe ".unsafe_expanded" do
    it "names a header whose value only becomes unsafe after $VAR expansion" do
      saved = Gori::Settings.env_vars
      saved_p = Gori::Settings.project_env_vars
      saved_x = Gori::Settings.env_prefix
      begin
        Gori::Settings.env_prefix = "$"
        Gori::Settings.project_env_vars = [] of {String, String}
        Gori::Settings.env_vars = [{"TOKEN", "abc\ndef"}, {"CLEAN", "abc"}]
        H.unsafe_expanded([{"Authorization", "Bearer $TOKEN"}]).should eq(["Authorization"])
        # The complement, three ways: a clean var, a literal value, and an UNRESOLVED token
        # (which `Env.expand` leaves as the harmless characters `$NOPE` — the unresolved
        # refusal is a different check and owns that case).
        H.unsafe_expanded([{"Authorization", "Bearer $CLEAN"},
                           {"X-Lit", "plain"},
                           {"X-Un", "Bearer $NOPE"}]).should be_empty
      ensure
        Gori::Settings.env_vars = saved || [] of {String, String}
        Gori::Settings.project_env_vars = saved_p || [] of {String, String}
        Gori::Settings.env_prefix = saved_x || "$"
      end
    end
  end

  describe ".merge" do
    it "emits the Accept/User-Agent defaults with no user headers" do
      H.merge([] of {String, String}).should eq([{"Accept", "*/*"}, {"User-Agent", "gori-discover"}])
    end

    it "replaces a default in place (case-insensitive), keeping the default's casing" do
      H.merge([{"user-agent", "mycrawler"}]).should eq(
        [{"Accept", "*/*"}, {"User-Agent", "mycrawler"}])
    end

    it "appends an extra user header after the defaults" do
      H.merge([{"Authorization", "Bearer t"}]).should eq(
        [{"Accept", "*/*"}, {"User-Agent", "gori-discover"}, {"Authorization", "Bearer t"}])
    end

    it "ignores forced Host/Connection headers from the user" do
      H.merge([{"Host", "evil"}, {"Connection", "keep-alive"}]).should eq(
        [{"Accept", "*/*"}, {"User-Agent", "gori-discover"}])
    end
  end

  describe ".from_flow" do
    it "keeps auth/cookie/UA headers and drops Host + framing headers" do
      head = "GET /x HTTP/1.1\r\n" \
             "Host: h.example\r\n" \
             "Cookie: sid=1\r\n" \
             "Authorization: Bearer t\r\n" \
             "User-Agent: curl/8\r\n" \
             "Content-Length: 5\r\n" \
             "Connection: keep-alive\r\n\r\n"
      H.from_flow(head.to_slice).should eq(
        [{"Cookie", "sid=1"}, {"Authorization", "Bearer t"}, {"User-Agent", "curl/8"}])
    end

    it "returns no headers when the flow carries only framing headers" do
      head = "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"
      H.from_flow(head.to_slice).should be_empty
    end
  end
end
