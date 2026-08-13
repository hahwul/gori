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

    it "collapses a TRAILING bare dot, which the other dot-segment shapes do not cover" do
      # `/a/.` trips none of `..`, `./`, `//`, so it used to survive un-normalized — the one
      # dot-segment shape `parse` let through. It matters since #395 derives the brute-force
      # base from the seed's path: a `@confine_path` of `/api/.` is unsatisfiable, because
      # every URL derived from it comes back through here normalized.
      U.parse("http://h/a/.").not_nil!.path.should eq("/a")
      U.parse("http://h/.").not_nil!.path.should eq("/")
      # A leading dot is an ordinary segment name and must NOT be touched.
      U.parse("http://h/a/.env").not_nil!.path.should eq("/a/.env")
      U.parse("http://h/.well-known/x").not_nil!.path.should eq("/.well-known/x")
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

    # A 3xx `Location` is the one href that reaches `resolve` straight off the wire — every
    # page-derived link came through `Extract`, which scrubs. The scheme test used to be a
    # Regex, and PCRE2 raises ArgumentError on invalid UTF-8; `downcase` keeps a lone Latin-1
    # octet intact, so this href raised instead of resolving. It runs on discover's
    # orchestrator fiber, so the raise ended the whole run.
    it "resolves a relative href that is not valid UTF-8 instead of raising out of PCRE2" do
      base = U.parse("http://h/app/index.html").not_nil!
      href = String.new(Bytes[0x63, 0x61, 0x66, 0xe9, 0x2f, 0x78]) # "caf\xE9/x"
      href.valid_encoding?.should be_false
      U.resolve(base, href).should eq("http://h/app/#{href}")
      # The absolute-path form took a byte-safe branch and always worked — the control that
      # says this is about the scheme test, not about the href being odd.
      U.resolve(base, "/#{href}").should eq("http://h/#{href}")
    end

    it "still refuses a scheme-prefixed href with the byte scan the Regex used to do" do
      base = U.parse("http://h/p").not_nil!
      U.resolve(base, "ftp://h/x").should be_nil
      U.resolve(base, "svn+ssh://h/x").should be_nil
      U.resolve(base, "view-source:http://h/x").should be_nil
      # Not a scheme: the class stops at the first byte outside [a-z0-9+.-], so the ':' in a
      # query or a path segment must not make a relative href look absolute.
      U.resolve(base, "c?x=a:b").should eq("http://h/c?x=a:b")
      U.resolve(base, "2fa:x").should eq("http://h/2fa:x") # a scheme cannot start with a digit
    end

    # SUSPECTED BUG: resolve() checks the absolute-URL prefix case-sensitively
    # (h.starts_with?("http://")), so an uppercase scheme falls through to the
    # "some other scheme" branch and returns nil. HTML/URL schemes are
    # case-insensitive (RFC 3986 §3.1) and the doc comment promises to "Handle
    # absolute ... forms", so an uppercase absolute URL should resolve, not drop.
    it "resolves an uppercase absolute scheme (schemes are case-insensitive)" do
      base = U.parse("http://h/p").not_nil!
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

  # Issue #394. `Sender#build_get` writes "GET #{target} HTTP/1.1", so space is the request
  # line's field separator — and `URI.parse` keeps a raw one verbatim in both path and query.
  # The class is every octet <= 0x20 plus DEL; the remedy splits by what the octet does.
  describe "request-line octets" do
    # The class itself has ONE home (`Codec::Http1.request_token_safe?`, #397) and is specced
    # there. What has to be pinned HERE is that Discover's per-octet repair set agrees with it
    # exactly: the encoder needs a per-BYTE test and cannot call a string predicate once per
    # byte, so the class is written twice — this is what stops the two drifting.
    it "encodes exactly the class the codec refuses, minus the framing pair" do
      # The expectation is DERIVED from the codec's predicate, never a second copy of the
      # range, so widening the class there and not here fails this example. Measured through
      # `parse` rather than the private per-byte helper: what matters is the octet a request
      # line would carry. NUL is skipped — `URI.parse` truncates the path at one, so it never
      # reaches the encoder to be observed.
      (0x01..0x7F).each do |b|
        c = b.unsafe_chr
        path = U.parse("http://h/x#{c}y").try(&.path)
        next if path.nil?
        refused = !Gori::Proxy::Codec::Http1.request_token_safe?(c.to_s)
        framing = b == 0x0d || b == 0x0a
        if refused && !framing
          path.should eq("/x%#{b.to_s(16, upcase: true).rjust(2, '0')}y"), "octet 0x#{b.to_s(16)}"
        elsif framing
          path.should eq("/x#{c}y"), "framing octet 0x#{b.to_s(16)} must stay raw"
        end
      end
    end

    describe "the codec's class, as Discover applies it" do
      it "is false for every octet <= 0x20 and for DEL, true above them" do
        (0..0x20).each { |b| Gori::Proxy::Codec::Http1.request_token_safe?("/a#{b.unsafe_chr}b").should be_false }
        Gori::Proxy::Codec::Http1.request_token_safe?("/a\u007Fb").should be_false
        Gori::Proxy::Codec::Http1.request_token_safe?("/a~b").should be_true # 0x7E, the char below DEL
        Gori::Proxy::Codec::Http1.request_token_safe?("/my%20file.pdf?q=1&r=2").should be_true
      end

      it "is true for a multi-byte UTF-8 path (the check is byte-wise, not char-wise)" do
        # Every continuation byte is >= 0x80, so a non-ASCII path must not be caught by a
        # test written against the 0x00..0x20 range.
        Gori::Proxy::Codec::Http1.request_token_safe?("/문서/파일.pdf").should be_true
      end
    end

    describe ".parse" do
      it "percent-encodes a raw space in the path — the #394 repro" do
        # `<a href="/my file.pdf">` is ordinary handwritten HTML; a browser fetches
        # /my%20file.pdf. Rejecting it would silently shrink the crawl's coverage.
        p = U.parse("http://h/my file.pdf").not_nil!
        p.path.should eq("/my%20file.pdf")
        Gori::Proxy::Codec::Http1.request_token_safe?(p.path).should be_true
      end

      it "percent-encodes a raw space in the query" do
        p = U.parse("http://h/s?q=1 2&r=3").not_nil!
        p.query.should eq("q=1%202&r=3")
      end

      it "percent-encodes TAB, DEL and the other C0 octets" do
        U.parse("http://h/a\tb").not_nil!.path.should eq("/a%09b")
        U.parse("http://h/a\u007Fb").not_nil!.path.should eq("/a%7Fb")
        U.parse("http://h/a\vb").not_nil!.path.should eq("/a%0Bb")
      end

      it "leaves CR and LF RAW so the refusal gates still see them (#390's disposition)" do
        # The framing half is dropped, not repaired: `Headers.safe_url?` refuses such a URL at
        # every enqueue and `Sender#fetch` refuses it at the wire. Encoding it here would turn
        # a splice attempt into a real request for a URL nobody authored.
        p = U.parse("http://h/a\r\nX-Injected: 1").not_nil!
        # The space in the injected header line IS encoded — the two halves are independent,
        # and what matters is that the CR/LF survive so the gates below can still refuse.
        p.path.should eq("/a\r\nX-Injected:%201")
        Gori::Discover::Headers.safe_url?(p).should be_false
        Gori::Proxy::Codec::Http1.request_token_safe?(p.path).should be_false
      end

      it "is idempotent — an already-encoded path never becomes %2520" do
        # `#{bl.dir}#{cand}` re-parses a path this method produced, and so does every
        # re-crawled link. `%` is not in the class, so nothing re-encodes.
        once = U.parse("http://h/my file.pdf").not_nil!
        twice = U.parse(U.normalize(once)).not_nil!
        twice.path.should eq("/my%20file.pdf")
        U.parse("http://h/a%20b").not_nil!.path.should eq("/a%20b")
      end

      it "refuses a host carrying a request-line octet rather than encoding it" do
        # `URI.parse("http://a b/x").host` is "a b" verbatim. Percent-encoding is defined for
        # a path, not a reg-name, so there is nothing to repair — nil, the same exit every
        # unparseable URL takes.
        U.parse("http://a b/x").should be_nil
        U.parse("http://h /x").should be_nil
        U.parse("http://ev\r\nil.test/a").should be_nil
      end

      it "gives the URL ONE spelling across identity, the gate question and the finding" do
        # The reason this is repaired at parse and not in `build_get`: these five strings all
        # come off the same Parts, and a raw space left in any of them would make the scope
        # judge a different URL than the one sent, and `Persist` write a corrupt Sitemap row.
        p = U.parse("http://h/my file.pdf?q=a b").not_nil!
        U.normalize(p).should eq("http://h/my%20file.pdf?q=a%20b")
        U.gate_url(p).should eq("http://h/my%20file.pdf?q=a%20b")
        U.visit_key(p).should eq("http://h/my%20file.pdf?q=a%20b")
        U.template_key(p).should eq("http://h/my%20file.pdf?q")
        U.dir_of(p).should eq("http://h/")
      end
    end

    describe ".resolve into .parse" do
      it "carries a spaced href through to an encoded, sendable URL" do
        base = U.parse("http://h/dir/page").not_nil!
        abs = U.resolve(base, "my file.pdf").not_nil!
        U.parse(abs).not_nil!.path.should eq("/dir/my%20file.pdf")
      end
    end
  end

  # `Url.probe` is an OPTIMIZATION of `parse("#{dir_url}#{cand}")` and is never allowed to be
  # a second opinion — `enqueue_probes` picks whichever ran, so a one-byte disagreement would
  # send a URL the gates were never asked about. These pin equivalence where it answers and
  # refusal (→ the caller's `parse` fallback) where it does not.
  describe ".probe" do
    dir_url = "https://acme.test/shop/catalog/"
    dir = U.parse(dir_url).not_nil!

    it "agrees with .parse on every entry of the built-in wordlist, plus extensions" do
      words = Gori::Discover::Wordlist.builtin
      words.size.should be > 300 # the list is the point of the sweep; a stub would prove nothing
      answered = 0
      words.each do |w|
        [w, "#{w}.php", "#{w}.json", "#{w}.bak"].each do |cand|
          fast = U.probe(dir, dir_url, cand)
          next unless fast
          answered += 1
          slow = U.parse("#{dir_url}#{cand}").not_nil!
          fast.parts.should eq(slow)
          # ONE string standing in for both, which is the whole allocation win: they are
          # equal for any query-less URL, and `probe` only ever produces query-less ones.
          fast.url.should eq(U.normalize(slow))
          fast.url.should eq(U.visit_key(slow))
        end
      end
      # Guards the sweep itself: a `plain_bytes?` that refused everything would pass silently.
      answered.should eq(words.size * 4)
    end

    it "builds the candidate under the directory's own origin and path" do
      pr = U.probe(dir, dir_url, ".well-known/security.txt").not_nil!
      pr.url.should eq("https://acme.test/shop/catalog/.well-known/security.txt")
      pr.parts.path.should eq("/shop/catalog/.well-known/security.txt")
      pr.parts.query.should be_nil
    end

    it "keeps a non-default port, which is part of the resource's identity" do
      d = U.parse("http://acme.test:8080/api/").not_nil!
      U.probe(d, "http://acme.test:8080/api/", "admin").not_nil!
        .url.should eq("http://acme.test:8080/api/admin")
    end

    it "declines every candidate parse would have rewritten, split or refused" do
      # A dot-segment: `parse` collapses it, so the concatenation would name a different
      # resource than the one the gates judged. Traversal entries are common in public lists.
      U.probe(dir, dir_url, "../admin").should be_nil
      U.probe(dir, dir_url, "a/./b").should be_nil
      U.probe(dir, dir_url, "sub/..").should be_nil
      U.probe(dir, dir_url, "trailing/.").should be_nil
      # An empty segment: `//` collapses too.
      U.probe(dir, dir_url, "/admin").should be_nil
      U.probe(dir, dir_url, "a//b").should be_nil
      # `URI.parse` would split these off as query and fragment.
      U.probe(dir, dir_url, "search?q=1").should be_nil
      U.probe(dir, dir_url, "page#frag").should be_nil
      # The request-line octet class: SP and TAB `encode_unsafe` repairs, CR/LF
      # `Headers.safe_url?` refuses. Either way `parse` is the authority, not this.
      U.probe(dir, dir_url, "zzadmin ").should be_nil
      U.probe(dir, dir_url, "zz\tadmin").should be_nil
      U.probe(dir, dir_url, "zz\radmin").should be_nil
      U.probe(dir, dir_url, "zz\nadmin").should be_nil
      U.probe(dir, dir_url, "del\u{7f}").should be_nil
      U.probe(dir, dir_url, "").should be_nil
    end

    # The built-in list is one corpus and proves the fast path works on it; this proves it
    # cannot be WRONG on anything else, which is the property `enqueue_probes` relies on when it
    # takes whichever derivation answered. `--wordlist` is operator-supplied, so the corpus is
    # not the boundary.
    it "either agrees with parse or declines, for every octet in every position" do
      disagree = [] of String
      (0..255).each do |b|
        ["a#{b.unsafe_chr}b", "#{b.unsafe_chr}x", "x#{b.unsafe_chr}"].each do |cand|
          next unless cand.valid_encoding?
          next unless fast = U.probe(dir, dir_url, cand)
          slow = U.parse("#{dir_url}#{cand}")
          if slow.nil?
            disagree << "0x#{b.to_s(16)} #{cand.inspect}: probe answered where parse refused"
            next
          end
          disagree << "0x#{b.to_s(16)} #{cand.inspect}: #{fast.parts} != #{slow}" if fast.parts != slow
          disagree << "0x#{b.to_s(16)} #{cand.inspect}: #{fast.url.inspect} != #{U.normalize(slow).inspect}" if fast.url != U.normalize(slow)
          disagree << "0x#{b.to_s(16)} #{cand.inspect}: key #{fast.url.inspect} != #{U.visit_key(slow).inspect}" if fast.url != U.visit_key(slow)
        end
      end
      disagree.should be_empty
    end

    # The specific shape that broke it, kept as its own case because the octet sweep above
    # would not name it: `URI.parse` RSTRIPS the path with the UNICODE `Char#whitespace?`, so a
    # trailing U+00A0 / U+3000 / U+2028 vanishes from `parse`'s answer while a byte-level guard
    # sees three perfectly ordinary octets. A copy-pasted or HTML-scraped wordlist carries
    # trailing NBSP routinely; the fast path used to keep it and request a URL the fallback
    # never would.
    it "declines a candidate whose trailing character parse would strip" do
      ["\u{a0}", "\u{3000}", "\u{2028}"].each do |ws|
        U.probe(dir, dir_url, "admin#{ws}").should be_nil
        U.parse("#{dir_url}admin#{ws}").not_nil!.path.should eq("/shop/catalog/admin")
      end
      # Non-ASCII is declined wholesale, not just at the end — the guard is per byte and the
      # predicate it is standing in for is per character.
      U.probe(dir, dir_url, "관리자").should be_nil
      U.probe(dir, dir_url, "café").should be_nil
      # …and the fallback still reaches those candidates, so declining costs coverage nothing.
      U.parse("#{dir_url}관리자").not_nil!.path.should eq("/shop/catalog/관리자")
    end

    it "leaves an already-encoded candidate alone, exactly as parse does" do
      # `%` is not in the repair class, so neither derivation re-encodes it.
      pr = U.probe(dir, dir_url, "my%20file.pdf").not_nil!
      pr.parts.should eq(U.parse("#{dir_url}my%20file.pdf").not_nil!)
    end
  end
end
