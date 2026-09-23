require "./spec_helper"

# `$GEN.USER_AGENT` follows the TLS preset the request's own handshake presents (#1153).
#
# A seam spec: the property holds only if EVERY path that puts a `$GEN` value on a wire mints it
# in a context that knows the dial, and those paths live in six subsystems. The risk the issue
# named is not a wrong rule but a forgotten site — one `Generation.new` left on a send path mints
# a Firefox UA over a Chrome ClientHello with no error anywhere. So the sweep below holds every
# dial-less construction in `src/gori` to a NAMED reason, and a new one fails here until it
# either uses `Generation.for_dial` or earns an entry.

private SRC = File.join(__DIR__, "..", "src", "gori")

# file (relative to src/gori) → how many dial-less constructions it may hold, and why.
private DIAL_LESS = {
  "env.cr"                => {3, "the Env layer's own fallbacks, for a caller that passed no context"},
  "env_migration.cr"      => {2, "the migration's equivalence check: pre-seeded sentinels, never sent"},
  "bindings.cr"           => {1, "Bindings#overlay's fallback when its caller passed no context"},
  "tui/intercept_view.cr" => {1, "a placeholder replaced by for_dial when the first held item loads"},
  "authorize/passive.cr"  => {2, "a predicate over bytes it throws away"},
}

private def with_tls_rules(rules : Array(Gori::Settings::OutboundTlsRule), &)
  previous = Gori::Settings.outbound_tls
  Gori::Settings.outbound_tls = rules
  begin
    yield
  ensure
    Gori::Settings.outbound_tls = previous
  end
end

private def family_of(ua : String) : String?
  Gori::Env.user_agent_family(ua)
end

describe "the send seam's $GEN context" do
  it "names the dial at every construction, or a reason it cannot" do
    found = Hash(String, Int32).new(0)
    Dir.glob(File.join(SRC, "**", "*.cr")).each do |path|
      rel = path.lchop(SRC + "/")
      File.each_line(path) do |line|
        next if line.lstrip.starts_with?("#")
        found[rel] += line.scan(/Generation\.new\b/).size
      end
    end
    found.reject! { |_, n| n.zero? }
    found.should eq(DIAL_LESS.transform_values(&.[0]))
  end

  # The implicit door: an expansion that may mint `$GEN` but is handed no context lets the Env
  # layer create a dial-less one. Every such call outside the Env layer passes one — a named
  # context, not `generation: nil` — or resolves only BIND (which mints nothing). `Env.expand`
  # and `expand_wire` count when they are asked to resolve GEN.
  it "hands every send-side expansion a context" do
    send_call = /Env\.(expand_bindings(_as|_frame)?|overlay_slot)\(/
    gen_call = /Env\.(expand|expand_wire)\(/
    passed = /generation:\s*(?!nil\b)[\w@]|Generation\.for_dial|[(,]\s*(\w+_)?gen\s*\)/
    bare = [] of String
    Dir.glob(File.join(SRC, "**", "*.cr")).each do |path|
      rel = path.lchop(SRC + "/")
      next if rel == "env.cr"
      lines = File.read_lines(path)
      lines.each_with_index do |line, i|
        next if line.lstrip.starts_with?("#")
        # The call and its continuation lines, code only: a comment naming a context is not one.
        statement = lines[i, 3].map { |l| l.lstrip.starts_with?("#") ? "" : l.split(" # ")[0] }.join(" ")
        mints = line.matches?(send_call) ||
                (line.matches?(gen_call) && statement.matches?(/Owns::Gen|SEND_OWNS/))
        next unless mints
        next if statement.matches?(passed) || statement.includes?("Owns::Bind)")
        bare << "#{rel}:#{i + 1}: #{line.strip}"
      end
    end
    bare.should be_empty
  end
end

describe "Env.ua_family_for" do
  it "reads the send's own preset first, then the destination rule, on a TLS leg only" do
    with_tls_rules([Gori::Settings::OutboundTlsRule.new(host: "fx.test", preset: "firefox"),
                    Gori::Settings::OutboundTlsRule.new(host: "curl.test", preset: "curl")]) do
      Gori::Env.ua_family_for("fx.test", "https").should eq("FIREFOX")
      Gori::Env.ua_family_for("fx.test", "wss").should eq("FIREFOX")
      Gori::Env.ua_family_for("fx.test", "https", "Safari ").should eq("SAFARI") # override wins
      # A plaintext leg presents no fingerprint to agree with.
      Gori::Env.ua_family_for("fx.test", "http").should be_nil
      # A preset that names no browser, and no preset at all: the whole list.
      Gori::Env.ua_family_for("curl.test", "https").should be_nil
      Gori::Env.ua_family_for("plain.test", "https").should be_nil
    end
  end
end

describe "$GEN.USER_AGENT under a TLS preset" do
  it "draws from the preset's family, and from the whole list without one" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      20.times do
        gen = Gori::Env::Generation.for_dial("any.test", "https", "firefox")
        family_of(gen.value?("USER_AGENT").not_nil!).should eq("FIREFOX")
      end
      seen = Array.new(64) { family_of(Gori::Env::Generation.for_dial("any.test", "http").value?("USER_AGENT").not_nil!) }
      seen.uniq.size.should be > 1
      # An explicit family name is the operator's own choice and never overridden.
      gen = Gori::Env::Generation.for_dial("any.test", "https", "chrome")
      family_of(gen.value?("USER_AGENT_SAFARI").not_nil!).should eq("SAFARI")
    end
  end

  # The plain name promises the operator's list, not a browser: with none of their lines in the
  # preset's family it keeps drawing from all of them (an engagement's identifying UA stays), and
  # with some it narrows to those.
  it "keeps the operator's own list when it has no line of the preset's family" do
    previous = Gori::Settings.user_agents
    begin
      Gori::Settings.user_agents = ["MyScanner/1.0 (engagement-42)"]
      Gori::Env.user_agents_following("CHROME").should eq(["MyScanner/1.0 (engagement-42)"])
      firefox = "Mozilla/5.0 (X11; rv:156.0) Gecko/20100101 Firefox/156.0"
      Gori::Settings.user_agents = ["MyScanner/1.0", firefox]
      Gori::Env.user_agents_following("FIREFOX").should eq([firefox])
      Gori::Env.user_agents_following(nil).should eq(["MyScanner/1.0", firefox])
    ensure
      Gori::Settings.user_agents = previous
    end
    Gori::Env.user_agents_following("SAFARI").should eq(Gori::Env::USER_AGENT_FAMILIES["SAFARI"])
  end

  # End to end through the Repeater send seam: the bytes `wire` hands the socket.
  it "reaches the wire through Repeater::Sender with the tab's preset" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      sender = Gori::Repeater::Sender.new(ungated_outbound, scheme: "https", host: "any.test",
        port: 443, verify: false, tls_preset: "safari")
      10.times do
        wire = String.new(sender.wire("GET / HTTP/1.1\r\nHost: any.test\r\nUser-Agent: $GEN.USER_AGENT\r\n\r\n".to_slice))
        ua = wire.match(/User-Agent: ([^\r]+)\r\n/).not_nil![1]
        family_of(ua).should eq("SAFARI")
      end
    end
  end
end
