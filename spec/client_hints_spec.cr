require "./spec_helper"

private CH = Gori::ClientHints

private WIN_153 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"

private def ser(seed : Int32, brand : String?, version : String) : String
  CH.serialize(CH.brand_list(seed, brand, version))
end

private def apply(head : String, scheme : String? = "https", family : String? = "CHROME") : String
  String.new(CH.apply(head.to_slice, scheme) { family })
end

# The vectors below are Chromium's own: components/embedder_support/user_agent_utils_unittest.cc
# at the revision ClientHints pins (ab1ade5d1fa5f1c0b2bf80ab48d9b9cb25aa3c95). Each is quoted
# from the named TEST_F, major-version form; the additional-brand cases are an experiment path
# a shipping Chrome does not take, and are not ported.
describe "Gori::ClientHints, against Chromium's unit-test vectors" do
  it "GetGreasedUserAgentBrandVersion / ...FullVersions" do
    CH.greased_brand(84).should eq({"Not;A=Brand", "8"})
    CH.greased_brand(86).should eq({"Not?A_Brand", "24"})
  end

  it "GenerateBrandVersionListUnbranded / ...VerifySeedChanges" do
    ser(84, nil, "84").should eq(%("Not;A=Brand";v="8", "Chromium";v="84"))
    ser(85, nil, "85").should eq(%("Chromium";v="85", "Not=A?Brand";v="99"))
  end

  it "GenerateBrandVersionListWithBrand" do
    ser(84, "Totally A Brand", "84").should eq(%("Not;A=Brand";v="8", "Chromium";v="84", "Totally A Brand";v="84"))
  end

  it "GetGreasedUserAgentBrandVersionNoLeadingWhitespace" do
    110.times { |i| CH.greased_brand(i)[0][0].should_not eq(' ') }
  end

  it "GenerateBrandVersionListInvalidSeed" do
    expect_raises(ArgumentError) { CH.brand_list(-1, nil, "99") }
  end
end

describe "Gori::ClientHints.for_user_agent" do
  it "derives all three from a Chrome UA, seeded and versioned by its own major" do
    CH.for_user_agent(WIN_153).should eq([
      {"sec-ch-ua", ser(153, "Google Chrome", "153")},
      {"sec-ch-ua-mobile", "?0"},
      {"sec-ch-ua-platform", %("Windows")},
    ])
  end

  it "names the platform Chrome reports for each OS section it writes" do
    {
      "Macintosh; Intel Mac OS X 10_15_7" => %("macOS"),
      "X11; Linux x86_64"                 => %("Linux"),
      "X11; CrOS x86_64 14541.0.0"        => %("Chrome OS"),
      "Linux; Android 10; K"              => %("Android"),
    }.each do |os, platform|
      ua = "Mozilla/5.0 (#{os}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
      CH.for_user_agent(ua).not_nil![2].should eq({"sec-ch-ua-platform", platform})
    end
  end

  it "sets the mobile bit exactly for an Android phone UA" do
    phone = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36"
    CH.for_user_agent(phone).not_nil![1].should eq({"sec-ch-ua-mobile", "?1"})
  end

  # Another browser's brand is not in Chromium's source, so it is not guessed.
  it "sends nothing for a UA Chrome would not send" do
    [
      WIN_153 + " Edg/153.0.0.0",
      WIN_153 + " OPR/139.0.0.0",
      WIN_153.sub("Chrome/", "HeadlessChrome/"),
      "Mozilla/5.0 (X11; Linux x86_64; rv:156.0) Gecko/20100101 Firefox/156.0",
      "Mozilla/5.0 (Windows 95) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
      "curl/8.10.1",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36\xff",
    ].each { |ua| CH.for_user_agent(ua).should be_nil }
  end
end

describe "Gori::ClientHints.apply" do
  head = "GET / HTTP/1.1\r\nHost: a.test\r\nUser-Agent: #{WIN_153}\r\nAccept: */*\r\n\r\n"

  it "writes the set before the User-Agent line of an HTTPS request under the chrome preset" do
    apply(head).should eq(
      "GET / HTTP/1.1\r\nHost: a.test\r\n" \
      "sec-ch-ua: #{ser(153, "Google Chrome", "153")}\r\nsec-ch-ua-mobile: ?0\r\n" \
      "sec-ch-ua-platform: \"Windows\"\r\nUser-Agent: #{WIN_153}\r\nAccept: */*\r\n\r\n")
  end

  it "leaves the body byte-exact" do
    body = "\xff\r\n\r\nUser-Agent: x"
    req = "POST / HTTP/1.1\r\nUser-Agent: #{WIN_153}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    apply(req).should end_with("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  end

  it "keeps the User-Agent line's own terminator" do
    apply("GET / HTTP/1.1\nUser-Agent: #{WIN_153}\n\n").should contain("sec-ch-ua-platform: \"Windows\"\nUser-Agent:")
  end

  it "is the same object whenever nothing applies" do
    bytes = head.to_slice
    CH.apply(bytes, "http") { "CHROME" }.same?(bytes).should be_true       # plaintext: no hints
    CH.apply(bytes, "https") { "FIREFOX" }.same?(bytes).should be_true     # not the chrome preset
    CH.apply(bytes, "https") { nil }.same?(bytes).should be_true           # no preset
    CH.apply(bytes, nil) { raise "not asked" }.same?(bytes).should be_true # no dial, no lookup
    curl = "GET / HTTP/1.1\r\nUser-Agent: curl/8.10.1\r\n\r\n".to_slice
    CH.apply(curl, "https") { raise "not asked" }.same?(curl).should be_true # no Chrome UA, no lookup
  end

  # P7: an operator who wrote any hint owns the whole set.
  it "adds nothing beside an operator-typed hint" do
    typed = head.sub("Accept:", "Sec-CH-UA-Platform: \"Linux\"\r\nAccept:")
    apply(typed).should eq(typed)
    typed = head.sub("Accept:", "sec-ch-ua-arch: \"x86\"\r\nAccept:")
    apply(typed).should eq(typed)
  end

  it "adds nothing without exactly one User-Agent, or on a WebSocket handshake" do
    apply("GET / HTTP/1.1\r\nHost: a.test\r\n\r\n").should eq("GET / HTTP/1.1\r\nHost: a.test\r\n\r\n")
    twice = head.sub("Accept:", "User-Agent: #{WIN_153}\r\nAccept:")
    apply(twice).should eq(twice)
    ws = head.sub("Accept: */*", "Upgrade: websocket\r\nConnection: Upgrade")
    apply(ws).should eq(ws)
  end
end

# End to end through the Repeater seam, the one the three surfaces share: the hints agree with
# the `$GEN.USER_AGENT` minted for the same request, because they are read off it.
describe "client hints on the Repeater wire" do
  it "match the major of the User-Agent minted for the same request" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      sender = Gori::Repeater::Sender.new(ungated_outbound, scheme: "https", host: "any.test",
        port: 443, verify: false, tls_preset: "chrome")
      40.times do
        wire = String.new(sender.wire("GET / HTTP/1.1\r\nHost: any.test\r\nUser-Agent: $GEN.USER_AGENT\r\n\r\n".to_slice))
        ua = wire.match(/User-Agent: ([^\r]+)\r\n/).not_nil![1]
        if ua.includes?(" Edg/")
          wire.should_not contain("sec-ch-ua") # Edge's brand is not Chromium's to state
        else
          major = ua.match(/Chrome\/(\d+)/).not_nil![1]
          wire.should contain(%("Google Chrome";v="#{major}"))
          wire.should contain(%("Chromium";v="#{major}"))
        end
      end
    end
  end

  it "adds none under another preset or none" do
    {"firefox", nil}.each do |preset|
      sender = Gori::Repeater::Sender.new(ungated_outbound, scheme: "https", host: "any.test",
        port: 443, verify: false, tls_preset: preset)
      String.new(sender.wire("GET / HTTP/1.1\r\nUser-Agent: #{WIN_153}\r\n\r\n".to_slice)).should_not contain("sec-ch-ua")
    end
  end
end
