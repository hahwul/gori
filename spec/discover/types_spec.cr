require "../spec_helper"

private alias C = Gori::Discover::Containment

describe Gori::Discover::Containment do
  describe ".parse?" do
    it "decodes the strict / same-origin aliases to SameOrigin" do
      C.parse?("same-origin").should eq(C::SameOrigin)
      C.parse?("origin").should eq(C::SameOrigin)
      C.parse?("strict").should eq(C::SameOrigin)
    end

    it "decodes the host+subdomains aliases to HostAndSubdomains" do
      C.parse?("host").should eq(C::HostAndSubdomains)
      C.parse?("subdomains").should eq(C::HostAndSubdomains)
      C.parse?("host+subdomains").should eq(C::HostAndSubdomains)
      C.parse?("host-and-subdomains").should eq(C::HostAndSubdomains)
      C.parse?("host-subdomains").should eq(C::HostAndSubdomains)
    end

    it "decodes the scope aliases to ScopeAware" do
      C.parse?("scope").should eq(C::ScopeAware)
      C.parse?("scoped").should eq(C::ScopeAware)
      C.parse?("scope-aware").should eq(C::ScopeAware)
    end

    it "round-trips every #label back to its own value" do
      C.each do |value|
        C.parse?(value.label).should eq(value)
      end
    end

    it "is case-insensitive (SCOPE -> ScopeAware)" do
      C.parse?("SCOPE").should eq(C::ScopeAware)
      C.parse?("Origin").should eq(C::SameOrigin)
      C.parse?("STRICT").should eq(C::SameOrigin)
      C.parse?("ScOpE-AwArE").should eq(C::ScopeAware)
      C.parse?("HOST+SUBDOMAINS").should eq(C::HostAndSubdomains)
    end

    it "strips surrounding whitespace and folds separator runs to a hyphen" do
      # "  Host_And_Subdomains  " -> strip -> underscores collapsed to '-'.
      C.parse?("  Host_And_Subdomains  ").should eq(C::HostAndSubdomains)
    end

    it "treats underscores and whitespace runs identically as a single hyphen" do
      C.parse?("scope_aware").should eq(C::ScopeAware)
      C.parse?("scope aware").should eq(C::ScopeAware)
      C.parse?("same_origin").should eq(C::SameOrigin)
      C.parse?("same origin").should eq(C::SameOrigin)
      # Mixed multi-char runs of spaces + underscores collapse to ONE hyphen each.
      C.parse?("host___and   subdomains").should eq(C::HostAndSubdomains)
      C.parse?("host _ and _ subdomains").should eq(C::HostAndSubdomains)
    end

    it "normalizes tab and newline whitespace like spaces" do
      C.parse?("\tstrict\n").should eq(C::SameOrigin)
      C.parse?("\r\nscope\t").should eq(C::ScopeAware)
      C.parse?("scope\taware").should eq(C::ScopeAware)
    end

    it "returns nil for the empty string" do
      C.parse?("").should be_nil
    end

    it "returns nil for a whitespace-only token (strips to empty)" do
      C.parse?("   ").should be_nil
      C.parse?("\t\n ").should be_nil
    end

    it "returns nil for unrecognized garbage" do
      C.parse?("garbage").should be_nil
      C.parse?("sameorigin").should be_nil # missing separator, no fold applies
      C.parse?("scopeaware").should be_nil
    end

    # Documented adversarial contract: a literal '+' with SURROUNDING spaces is
    # NOT a separator the normalizer folds. The spaces collapse to hyphens but the
    # '+' survives, yielding "host-+-subdomains", which matches no case -> nil.
    # (Contrast "host+subdomains" with no spaces, which IS a literal alias.)
    it "returns nil for 'host + subdomains' (spaced plus survives normalization)" do
      C.parse?("host + subdomains").should be_nil
      C.parse?("host  +  subdomains").should be_nil
    end

    it "does not fold a plus that is not adjacent to whitespace" do
      # No whitespace/underscore anywhere -> '+' passes through untouched.
      C.parse?("host+subdomains").should eq(C::HostAndSubdomains)
      # But an internal alias built purely of hyphens must be exact.
      C.parse?("host+and+subdomains").should be_nil
    end

    it "returns nil when separators sit at the edges (strip only removes whitespace, not underscores)" do
      # Underscores are NOT stripped; they fold to leading/trailing hyphens,
      # so "_strict_" -> "-strict-" which matches nothing.
      C.parse?("_strict_").should be_nil
      C.parse?("-scope-").should be_nil
    end

    it "returns nil for multibyte / CJK / emoji tokens" do
      C.parse?("안녕").should be_nil
      C.parse?("世界").should be_nil
      C.parse?("🔥scope🔥").should be_nil
      C.parse?("scｏpe").should be_nil # fullwidth latin, not ascii 'o'
    end

    it "returns nil for tokens with combining marks around a real alias" do
      C.parse?("scopé").should be_nil # 'scope' + combining acute accent
    end

    it "does not misfire on partial or embedded aliases" do
      C.parse?("strictly").should be_nil
      C.parse?("prescope").should be_nil
      C.parse?("host+subdomains+extra").should be_nil
    end

    it "handles a huge adversarial whitespace/underscore run without pathological slowdown" do
      # Linear [\s_]+ fold — a megabyte of separators must collapse and return
      # quickly (regression guard against catastrophic backtracking).
      big = "scope" + (" _" * 500_000) + "aware"
      elapsed = Time.measure do
        # Collapses to "scope-aware" -> ScopeAware.
        C.parse?(big).should eq(C::ScopeAware)
      end
      elapsed.should be < 2.seconds
    end

    it "returns nil (not a crash) for an all-separator adversarial blob" do
      C.parse?("_ _ _ _ _".rjust(100_000, ' ')).should be_nil
    end
  end
end
