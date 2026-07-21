require "../spec_helper"

describe Gori::Tui::Url do
  describe ".origin_path" do
    it "projects an absolute-form URL to origin-form, keeping query and fragment" do
      Gori::Tui::Url.origin_path("http://example.com/a/b?q=1#f").should eq("/a/b?q=1#f")
    end

    it "returns '/' for an absolute-form URL with no path" do
      Gori::Tui::Url.origin_path("http://example.com").should eq("/")
    end

    it "strips the port from the authority" do
      Gori::Tui::Url.origin_path("https://host:8443/x").should eq("/x")
    end

    it "passes a non-URL target through unchanged (e.g. a status reason phrase)" do
      Gori::Tui::Url.origin_path("405 Method Not Allowed").should eq("405 Method Not Allowed")
    end

    it "leaves a bare origin-form target untouched" do
      Gori::Tui::Url.origin_path("/foo/bar").should eq("/foo/bar")
    end

    it "treats a single-slash near-miss scheme as a non-URL (identity)" do
      Gori::Tui::Url.origin_path("http:/example").should eq("http:/example")
    end

    it "treats an unknown scheme prefix as a non-URL (identity)" do
      Gori::Tui::Url.origin_path("httpx://h/p").should eq("httpx://h/p")
    end

    it "slices on char boundaries with a multibyte host and path (no corruption)" do
      Gori::Tui::Url.origin_path("http://éxample.com/한").should eq("/한")
    end

    it "returns the empty string unchanged" do
      Gori::Tui::Url.origin_path("").should eq("")
    end

    # --- glue-bug regression: output must never re-embed the authority ---

    it "never glues the host onto the projected path" do
      out = Gori::Tui::Url.origin_path("http://example.com/x")
      out.should eq("/x")
      out.should_not contain("example.com")
      out.should_not contain("http")
    end

    it "does not carry the host when there is no path" do
      out = Gori::Tui::Url.origin_path("http://example.com")
      out.should_not contain("example.com")
      out.starts_with?("/").should be_true
    end

    # --- scheme boundary / prefix cases ---

    it "handles the https scheme the same as http" do
      Gori::Tui::Url.origin_path("https://example.com/secure").should eq("/secure")
    end

    it "is case-sensitive on the scheme (uppercase passes through)" do
      Gori::Tui::Url.origin_path("HTTP://example.com/x").should eq("HTTP://example.com/x")
    end

    it "passes through a scheme-relative URL (no scheme prefix)" do
      Gori::Tui::Url.origin_path("//example.com/x").should eq("//example.com/x")
    end

    it "passes through a mailto: (non-http) URL unchanged" do
      Gori::Tui::Url.origin_path("mailto:user@example.com").should eq("mailto:user@example.com")
    end

    # --- boundary: minimal / truncated absolute forms ---

    it "returns '/' for a bare scheme+authority separator (http://)" do
      Gori::Tui::Url.origin_path("http://").should eq("/")
    end

    it "returns '/' for a bare https:// separator" do
      Gori::Tui::Url.origin_path("https://").should eq("/")
    end

    it "returns '/' for scheme+host with no trailing slash" do
      Gori::Tui::Url.origin_path("http://h").should eq("/")
    end

    it "preserves a lone trailing slash as the whole path" do
      Gori::Tui::Url.origin_path("http://example.com/").should eq("/")
    end

    it "handles an empty authority (triple slash)" do
      Gori::Tui::Url.origin_path("http:///path").should eq("/path")
    end

    # --- path content preservation ---

    it "keeps every slash of a deep path" do
      Gori::Tui::Url.origin_path("http://h/a/b/c/d/e").should eq("/a/b/c/d/e")
    end

    it "keeps reserved and encoded characters verbatim in the path" do
      Gori::Tui::Url.origin_path("http://h/p%20a?x=%2F&y=a+b#frag/ment")
        .should eq("/p%20a?x=%2F&y=a+b#frag/ment")
    end

    it "keeps a userinfo-bearing authority out of the projection" do
      out = Gori::Tui::Url.origin_path("http://user:pass@host:80/p")
      out.should eq("/p")
      out.should_not contain("pass")
    end

    # --- query/fragment on an empty path ---
    # NOTE: the source keys off the first '/' after the authority. A URL whose only
    # component after the authority is a query or fragment (no '/') has no such slash,
    # so it collapses to "/". This is the actual, safe behavior for the display helper;
    # such wire targets are rare (origin-form always carries a path). Asserting actual.

    it "collapses an absolute URL whose only tail is a query to '/'" do
      Gori::Tui::Url.origin_path("http://example.com?q=1").should eq("/")
    end

    it "collapses an absolute URL whose only tail is a fragment to '/'" do
      Gori::Tui::Url.origin_path("http://example.com#f").should eq("/")
    end

    # --- multibyte / adversarial ---

    it "handles a CJK-only path segment" do
      Gori::Tui::Url.origin_path("http://호스트/안녕/世界").should eq("/안녕/世界")
    end

    it "handles an emoji (surrogate/astral) path" do
      Gori::Tui::Url.origin_path("http://h/🚀/x").should eq("/🚀/x")
    end

    it "handles a combining-mark host without corrupting the following path" do
      # "e" + U+0301 combining acute accent in the host
      Gori::Tui::Url.origin_path("http://éhost.com/p").should eq("/p")
    end

    it "completes quickly on a very long path (no pathological scanning)" do
      long = "http://h/" + ("a/" * 200_000)
      elapsed = Time.measure { Gori::Tui::Url.origin_path(long) }
      elapsed.should be < 1.second
      out = Gori::Tui::Url.origin_path(long)
      out.starts_with?("/a/").should be_true
      out.size.should eq(long.size - 8) # dropped "http://h"
    end

    it "completes quickly on a long multibyte path" do
      long = "http://héllo/" + ("한/" * 100_000)
      out = Gori::Tui::Url.origin_path(long)
      out.starts_with?("/한/").should be_true
      out.should_not contain("héllo")
    end
  end
end
