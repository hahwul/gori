require "./spec_helper"

# The two questions a bind address gets asked, which diverge the moment the bind is a
# wildcard: what to SHOW (display) versus what to CONNECT to (dial_host). Every surface
# that prints an address routes through here, so these examples are the single pin on
# "gori never tells the user to type an address that cannot work".
describe Gori::BindAddress do
  describe ".display" do
    it "renders a wildcard IPv4 bind as a dialable address plus the reachability note" do
      # "0.0.0.0:8070" is what these surfaces used to print. Nothing can connect to it,
      # so it is exactly the wrong thing to show next to "point your client here".
      Gori::BindAddress.display("0.0.0.0", 8070).should eq("localhost:8070 (all interfaces)")
    end

    it "renders both IPv6 wildcard spellings the same way" do
      Gori::BindAddress.display("::", 8070).should eq("localhost:8070 (all interfaces)")
      Gori::BindAddress.display("::0", 8070).should eq("localhost:8070 (all interfaces)")
    end

    it "treats a blank bind as a wildcard (it is caller-defaulted to loopback)" do
      Gori::BindAddress.display("", 8070).should eq("localhost:8070 (all interfaces)")
    end

    it "drops only the note when terse, never changing the address itself" do
      # The invariant that lets the width-constrained chips share this helper: a user
      # can never see two different addresses depending on which surface they look at.
      terse = Gori::BindAddress.display("0.0.0.0", 8070, terse: true)
      terse.should eq("localhost:8070")
      Gori::BindAddress.display("0.0.0.0", 8070).should start_with(terse)
    end

    it "collapses the canonical loopback spellings to localhost" do
      Gori::BindAddress.display("127.0.0.1", 8070).should eq("localhost:8070")
      Gori::BindAddress.display("::1", 9000).should eq("localhost:9000")
      Gori::BindAddress.display("localhost", 8070).should eq("localhost:8070")
    end

    it "leaves a concrete LAN IPv4 alone" do
      Gori::BindAddress.display("192.168.1.5", 8070).should eq("192.168.1.5:8070")
    end

    it "brackets a concrete IPv6 literal so host:port stays unambiguous" do
      # Bare interpolation produced "fe80::1:8080" — unparseable and not copy-pasteable.
      Gori::BindAddress.display("fe80::1", 8080).should eq("[fe80::1]:8080")
    end

    it "does not double-bracket an already-bracketed literal" do
      Gori::BindAddress.display("[fe80::1]", 8080).should eq("[fe80::1]:8080")
    end

    it "leaves a hostname alone" do
      Gori::BindAddress.display("proxy.example.com", 3128).should eq("proxy.example.com:3128")
    end

    it "keeps a non-canonical loopback alias literal (localhost would not reach it)" do
      Gori::BindAddress.display("127.0.0.2", 8070).should eq("127.0.0.2:8070")
      # …and every other 127/8 address, which is why this is an equality against the two
      # canonical loopbacks rather than `IPAddress#loopback?`.
      Gori::BindAddress.display("127.1.2.3", 8070).should eq("127.1.2.3:8070")
      Gori::BindAddress.display("::ffff:127.0.0.1", 8070).should eq("[::ffff:127.0.0.1]:8070")
    end

    # The same "one address, many spellings" rule `wildcard?` follows: `bind_host_error`
    # accepts every RFC 4291 form, so a string list would collapse one spelling of ::1 to
    # `localhost` and print the raw literal for another — the same bind, two readouts.
    it "collapses ::1 in any spelling, not just the two that were listed" do
      {"::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001", "::0:1",
       "[::1]"}.each do |h|
        Gori::BindAddress.display(h, 9000).should eq("localhost:9000")
      end
    end
  end

  describe ".dial_host" do
    it "collapses a wildcard to loopback OF THE SAME FAMILY" do
      # Family matters: a 0.0.0.0 listener is unreachable over ::1, and a :: listener is
      # unreachable over 127.0.0.1 unless the kernel is dual-stack. "localhost" would
      # leave that to the resolver's preference — the wrong-family hang we are avoiding.
      Gori::BindAddress.dial_host("0.0.0.0").should eq("127.0.0.1")
      Gori::BindAddress.dial_host("::").should eq("::1")
      Gori::BindAddress.dial_host("::0").should eq("::1")
      Gori::BindAddress.dial_host("").should eq("127.0.0.1")
    end

    it "returns a concrete bind unchanged" do
      Gori::BindAddress.dial_host("192.168.1.5").should eq("192.168.1.5")
      Gori::BindAddress.dial_host("127.0.0.1").should eq("127.0.0.1")
      Gori::BindAddress.dial_host("proxy.example.com").should eq("proxy.example.com")
    end

    it "returns a BARE host, stripping brackets (Firefox's host-only pref must not see them)" do
      Gori::BindAddress.dial_host("[fe80::1]").should eq("fe80::1")
    end
  end

  describe ".authority" do
    it "brackets IPv6 and leaves IPv4/hostnames bare" do
      Gori::BindAddress.authority("::1", 8070).should eq("[::1]:8070")
      Gori::BindAddress.authority("127.0.0.1", 8070).should eq("127.0.0.1:8070")
      Gori::BindAddress.authority("example.com", 8070).should eq("example.com:8070")
    end

    it "does NOT resolve a wildcard — that is dial_host's job" do
      Gori::BindAddress.authority("0.0.0.0", 8070).should eq("0.0.0.0:8070")
    end
  end

  describe ".wildcard?" do
    it "recognises every spelling bind_host_error accepts, and nothing else" do
      {"0.0.0.0", "::", "::0", "0:0:0:0:0:0:0:0", "[::]", ""}.each do |h|
        Gori::BindAddress.wildcard?(h).should be_true
      end
      {"127.0.0.1", "::1", "192.168.1.5", "localhost", "0.0.0.1"}.each do |h|
        Gori::BindAddress.wildcard?(h).should be_false
      end
    end

    # RFC 4291 §2.2 gives one address many spellings, and `Settings.bind_host_error` accepts
    # every one of them (`Socket::IPAddress.valid_v6?`). A hand-kept list of strings is
    # therefore a list a new spelling escapes — the same reason `Upstream.unspecified?` parses
    # the address instead of matching text. What escapes is not cosmetic: `dial_host` hands the
    # unresolved literal to the browser launcher (`--proxy-server=`) and to the setup page, so
    # the operator is told to point their client at an address nothing can connect to.
    it "recognises an all-zero address in any RFC 4291 spelling" do
      {"0000:0000:0000:0000:0000:0000:0000:0000", "0::0", "0:0:0::0", "::0.0.0.0",
       "[0000::0000]", " ::0 "}.each do |h|
        Gori::BindAddress.wildcard?(h).should be_true, "expected #{h.inspect} to be a wildcard"
        Gori::BindAddress.dial_host(h).should eq("::1")
        Gori::BindAddress.display(h, 8070).should eq("localhost:8070 (all interfaces)")
      end
    end

    it "still refuses an address that merely LOOKS all-zero" do
      {"0.0.0.1", "::2", "0000:0000:0000:0000:0000:0000:0000:0001", "0.0.0.0.0",
       "0-0-0-0"}.each do |h|
        Gori::BindAddress.wildcard?(h).should be_false, "expected #{h.inspect} not to be a wildcard"
      end
    end
  end
end
