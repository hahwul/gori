require "../spec_helper"

private alias U = Gori::Discover::Url

describe Gori::Discover::Url do
  it "folds numeric/uuid/hex/date path segments in the template key" do
    p1 = U.parse("http://h/user/1/edit").not_nil!
    p2 = U.parse("http://h/user/2/edit").not_nil!
    U.template_key(p1).should eq(U.template_key(p2))
    U.template_key(p1).should contain("{n}")

    u1 = U.parse("http://h/o/550e8400-e29b-41d4-a716-446655440000").not_nil!
    U.template_key(u1).should contain("{uuid}")
  end

  it "keeps query values in the visit key but drops them in the template key" do
    a = U.parse("http://h/s?page=1").not_nil!
    b = U.parse("http://h/s?page=2").not_nil!
    U.visit_key(a).should_not eq(U.visit_key(b))
    U.template_key(a).should eq(U.template_key(b))
  end

  it "normalizes host case and default port in the visit key" do
    U.visit_key(U.parse("http://H:80/x").not_nil!).should eq(U.visit_key(U.parse("http://h/x").not_nil!))
  end

  it "resolves relative, absolute-path, scheme-relative, absolute, and dot-segment links" do
    base = U.parse("http://h/a/b/page").not_nil!
    U.resolve(base, "c").should eq("http://h/a/b/c")
    U.resolve(base, "../x").should eq("http://h/a/x")
    U.resolve(base, "/root").should eq("http://h/root")
    U.resolve(base, "//other/z").should eq("http://other/z")
    U.resolve(base, "https://ext/y").should eq("https://ext/y")
    U.resolve(base, "mailto:a@b").should be_nil
    U.resolve(base, "javascript:void(0)").should be_nil
    U.resolve(base, "#frag").should be_nil
  end

  it "derives the directory of a url" do
    U.dir_of(U.parse("http://h/a/b/c").not_nil!).should eq("http://h/a/b/")
    U.dir_of(U.parse("http://h/").not_nil!).should eq("http://h/")
  end

  describe ".fold_segment" do
    it "folds a YYYY-MM-DD date to {date} (DATE_LEN 10)" do
      U.fold_segment("2021-01-01").should eq("{date}")
    end

    it "folds a 12+ char hex run to {hex} but leaves an 11-char run literal (HEX_MIN floor)" do
      U.fold_segment("a1b2c3d4e5f6").should eq("{hex}")      # exactly 12 bytes
      U.fold_segment("a1b2c3d4e5f6ff").should eq("{hex}")    # longer still folds
      U.fold_segment("abcdefabcde").should eq("abcdefabcde") # 11 bytes < HEX_MIN → literal
    end

    it "tests NUM before HEX so a 12-digit run folds to {n}, not {hex}" do
      U.fold_segment("123456789012").should eq("{n}")
      U.fold_segment("1").should eq("{n}")
    end

    it "leaves a non-ASCII segment as-is (ascii_only? guard) and downcases an ASCII one" do
      U.fold_segment("사용자").should eq("사용자")
      U.fold_segment("世界").should eq("世界")
      U.fold_segment("café").should eq("café") # accented byte is non-ASCII → returned as-is
      U.fold_segment("API").should eq("api")
      U.fold_segment("Index.HTML").should eq("index.html")
    end

    it "folds an UPPERCASE uuid to {uuid} (case-insensitive)" do
      U.fold_segment("550E8400-E29B-41D4-A716-446655440000").should eq("{uuid}")
      U.fold_segment("550e8400-e29b-41d4-a716-446655440000").should eq("{uuid}")
    end

    it "leaves an empty-ish ordinary segment untouched and passes plain words through" do
      U.fold_segment("users").should eq("users")
      U.fold_segment("edit").should eq("edit")
    end

    it "handles a huge adversarial segment quickly (byte-scan gates before PCRE)" do
      # Mirrors fuzz_spec: a large input must complete near-instantly. The all_digits?/
      # ascii_only? byte scans decide the outcome without a catastrophic regex walk.
      big_hex = "a1b2c3d4e5f6" * 20_000 # 240k bytes, all hex → {hex}
      big_num = "1" * 200_000           # 200k digits → {n}
      elapsed = Time.measure do
        U.fold_segment(big_hex).should eq("{hex}")
        U.fold_segment(big_num).should eq("{n}")
        U.fold_segment("x" * 200_000).should eq("x" * 200_000) # long non-hex letters → literal
      end
      elapsed.should be < 2.seconds
    end
  end

  describe ".parse" do
    it "returns nil for a non-http(s) scheme" do
      U.parse("ftp://h/x").should be_nil
      U.parse("file:///x").should be_nil
      U.parse("ws://h/x").should be_nil
    end

    it "returns nil for an empty / missing host" do
      U.parse("http:///x").should be_nil
      U.parse("not a url").should be_nil
      U.parse("").should be_nil
    end

    it "fills the default port per scheme" do
      U.parse("http://h/x").not_nil!.port.should eq(80)
      U.parse("https://h/x").not_nil!.port.should eq(443)
      U.parse("http://h:8080/x").not_nil!.port.should eq(8080)
    end

    it "omits the default port in normalize()/origin() but keeps an explicit one" do
      U.origin(U.parse("http://h/x").not_nil!).should eq("http://h")
      U.origin(U.parse("https://h/x").not_nil!).should eq("https://h")
      U.normalize(U.parse("http://h:80/x").not_nil!).should eq("http://h/x")
      U.origin(U.parse("http://h:8080/x").not_nil!).should eq("http://h:8080")
      U.normalize(U.parse("http://h:8080/x").not_nil!).should eq("http://h:8080/x")
    end

    it "collapses dot-segments in the parsed path" do
      U.parse("http://h/a/../b").not_nil!.path.should eq("/b")
      U.parse("http://h/a/./b").not_nil!.path.should eq("/a/b")
    end

    it "defaults an empty path to /" do
      U.parse("http://h").not_nil!.path.should eq("/")
    end
  end

  describe ".resolve" do
    it "re-appends the href's own query after path resolution" do
      base = U.parse("http://h/a/b/page").not_nil!
      U.resolve(base, "c?x=1").should eq("http://h/a/b/c?x=1")
      U.resolve(base, "/root?y=2&z=3").should eq("http://h/root?y=2&z=3")
    end

    it "returns nil for non-http pseudo-schemes and empty href" do
      base = U.parse("http://h/p").not_nil!
      U.resolve(base, "data:text/html,<b>").should be_nil
      U.resolve(base, "blob:http://h/uuid").should be_nil
      U.resolve(base, "about:blank").should be_nil
      U.resolve(base, "ws://h/x").should be_nil
      U.resolve(base, "").should be_nil
      U.resolve(base, "   ").should be_nil
    end

    # SUSPECTED BUG: resolve() checks the absolute-URL prefix case-sensitively
    # (h.starts_with?("http://")), so an uppercase scheme falls through to the
    # "some other scheme" branch and returns nil. HTML/URL schemes are
    # case-insensitive (RFC 3986 §3.1) and the doc comment promises to "Handle
    # absolute ... forms", so an uppercase absolute URL should resolve, not drop.
    pending "resolves an uppercase absolute scheme (schemes are case-insensitive)" do
      base = U.parse("http://h/p").not_nil!
      # Intended: the absolute URL is returned (browsers treat HTTP:// as http://).
      U.resolve(base, "HTTP://host/p").should eq("HTTP://host/p")
    end
  end

  describe ".normalize_path" do
    it "does not underflow past root when popping .. segments" do
      U.normalize_path("/a/../../b").should eq("/b")
      U.normalize_path("/../../../x").should eq("/x")
    end

    it "preserves a trailing slash" do
      U.normalize_path("/a/b/").should eq("/a/b/")
      U.normalize_path("/a/../b/").should eq("/b/")
    end

    it "drops a single-dot segment" do
      U.normalize_path("/a/./b").should eq("/a/b")
      U.normalize_path("/./").should eq("/")
    end

    it "reduces bare root to /" do
      U.normalize_path("/").should eq("/")
      U.normalize_path("//").should eq("/")
    end
  end

  describe "canonical_query (via keys)" do
    it "template_key folds the query to its deduped, sorted key set" do
      # fold:true — values dropped, keys sorted + uniq'd
      U.template_key(U.parse("http://h/s?b=2&a=1&a=9").not_nil!).should eq("http://h/s?a&b")
      U.template_key(U.parse("http://h/s?z=1").not_nil!).should eq("http://h/s?z")
    end

    it "visit_key keeps values and sorts pairs" do
      # fold:false — values kept, pairs sorted
      U.visit_key(U.parse("http://h/s?b=2&a=1").not_nil!).should eq("http://h/s?a=1&b=2")
    end

    it "rejects empty pairs from a doubled ampersand" do
      U.visit_key(U.parse("http://h/s?a=1&&b=2").not_nil!).should eq("http://h/s?a=1&b=2")
      U.template_key(U.parse("http://h/s?a=1&&b=2").not_nil!).should eq("http://h/s?a&b")
    end
  end
end
