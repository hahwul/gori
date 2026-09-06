require "./spec_helper"

# The ONE host-pattern dialect — Scope's `host` rules, the TLS passthrough list, the upstream
# routing rules and the outbound-TLS rules all compile through it, so what it folds away is
# folded away everywhere and what it does not is a spelling every one of those tables can be
# escaped by.
describe Gori::HostPattern do
  describe "#matches?" do
    it "matches the host itself and any subdomain, case-insensitively" do
      c = Gori::HostPattern::Compiled.new("acme.test")
      c.matches?("acme.test").should be_true
      c.matches?("api.acme.test").should be_true
      c.matches?("A.ACME.TEST").should be_true
      c.matches?("notacme.test").should be_false
      c.matches?("acme.test.evil.example").should be_false
    end

    it "reads a `*` as a glob, which does NOT match the bare host" do
      c = Gori::HostPattern::Compiled.new("*.acme.test")
      c.matches?("api.acme.test").should be_true
      c.matches?("a.b.acme.test").should be_true
      c.matches?("acme.test").should be_false
    end

    it "matches an IPv6 literal bracketed or bare, in either direction" do
      Gori::HostPattern::Compiled.new("::1").matches?("[::1]").should be_true
      Gori::HostPattern::Compiled.new("[::1]").matches?("::1").should be_true
    end

    # A TRAILING ROOT DOT names the same host to every resolver, and a browser sends it
    # verbatim in `Host:` when the user types one — it is a standing WAF/cache bypass for
    # exactly that reason. gori captures the wire bytes, so `acme.test.` reaches this dialect,
    # and a string compare made it a different host: a scope EXCLUDE, a TLS-passthrough entry
    # and an upstream route written for `acme.test` all silently stopped covering it, each in
    # the permissive direction. `OverrideHost.key` folds it away on the host-override table for
    # the same reason, and `Upstream.strip_root_dot` on the self-loop gate.
    it "folds a trailing root dot on the HOST, which names the same name" do
      c = Gori::HostPattern::Compiled.new("acme.test")
      c.matches?("acme.test.").should be_true
      c.matches?("api.acme.test.").should be_true
      c.matches?("ACME.TEST.").should be_true
      Gori::HostPattern::Compiled.new("*.acme.test").matches?("api.acme.test.").should be_true
    end

    it "folds a trailing root dot on the PATTERN, which would otherwise be a dead rule" do
      c = Gori::HostPattern::Compiled.new("acme.test.")
      c.matches?("acme.test").should be_true
      c.matches?("api.acme.test").should be_true
      c.matches?("acme.test.").should be_true
      c.matches?("other.test").should be_false
    end

    it "still refuses a host the dot fold must not reach" do
      c = Gori::HostPattern::Compiled.new("acme.test")
      c.matches?("acme.testx").should be_false
      c.matches?("acme.test.evil").should be_false
      c.matches?(".acme.test").should be_true # a leading dot is the subdomain arm, unchanged
    end

    it "treats a malformed glob as non-matching rather than raising on the hot path" do
      Gori::HostPattern::Compiled.new("[a-").matches?("anything").should be_false
    end
  end

  describe ".bare" do
    it "peels exactly a SURROUNDING bracket pair, never one bracket" do
      Gori::HostPattern.bare("[::1]").should eq("::1")
      Gori::HostPattern.bare("[::1").should eq("[::1")
      Gori::HostPattern.bare("::1]").should eq("::1]")
    end

    it "strips every trailing root dot, so `x..` cannot leave one behind" do
      Gori::HostPattern.bare("acme.test.").should eq("acme.test")
      Gori::HostPattern.bare("acme.test..").should eq("acme.test")
      Gori::HostPattern.bare("acme.test").should eq("acme.test")
      Gori::HostPattern.bare(".").should eq("")
    end
  end

  describe ".compile / .matches_any? / .match" do
    it "drops blank patterns and names the FIRST pattern that fired" do
      compiled = Gori::HostPattern.compile(["  ", "acme.test", "*.evil.test"])
      compiled.map(&.raw).should eq(["acme.test", "*.evil.test"])
      Gori::HostPattern.matches_any?(compiled, "api.acme.test.").should be_true
      Gori::HostPattern.match(compiled, "x.evil.test.").try(&.raw).should eq("*.evil.test")
      Gori::HostPattern.match(compiled, "evil.test").should be_nil
    end
  end
end
