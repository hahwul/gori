require "../spec_helper"

private alias E = Gori::Discover::Extract

# `from_html` returns `Extract::Found` (url + how the document yielded it) because it is the one
# extractor that runs BOTH the attribute passes and the endpoint pass. Most cases here are about
# WHICH urls come out, not how, so they go through this; the `declared` bit has its own cases at
# the bottom of the file.
private def html_hrefs(body : Bytes) : Array(String)
  E.from_html(body).map(&.href)
end

describe Gori::Discover::Extract do
  it "extracts href / src / action links from html" do
    body = %(<a href="/a">x</a> <img src='/b.png'> <form action="/submit"> <link href=/style.css>).to_slice
    links = html_hrefs(body)
    links.should contain("/a")
    links.should contain("/b.png")
    links.should contain("/submit")
    links.should contain("/style.css")
  end

  it "extracts a meta-refresh url" do
    body = %(<meta http-equiv="refresh" content="0; url=/next-page">).to_slice
    html_hrefs(body).should contain("/next-page")
  end

  it "extracts robots Disallow / Allow paths (skipping a bare slash)" do
    body = "User-agent: *\nDisallow: /admin\nAllow: /public\nDisallow: /\n# comment\n".to_slice
    links = E.from_robots(body)
    links.should contain("/admin")
    links.should contain("/public")
    links.should_not contain("/")
  end

  it "extracts sitemap <loc> urls" do
    body = "<urlset><url><loc>http://h/page1</loc></url><url><loc> http://h/page2 </loc></url></urlset>".to_slice
    links = E.from_sitemap(body)
    links.should contain("http://h/page1")
    links.should contain("http://h/page2")
  end

  it "sniffs sitemap bodies (urlset / sitemapindex / loc) apart from html and robots" do
    E.sitemap_body?(%(<?xml version="1.0"?><urlset><url><loc>http://h/p</loc></url></urlset>).to_slice).should be_true
    E.sitemap_body?(%(<sitemapindex><sitemap><loc>http://h/sm2.xml</loc></sitemap></sitemapindex>).to_slice).should be_true
    E.sitemap_body?(%(<html><body><a href="/loc">not a sitemap</a></body></html>).to_slice).should be_false
    E.sitemap_body?("User-agent: *\nDisallow: /admin\n".to_slice).should be_false
  end

  # (1) MAX_SCAN boundary: only hrefs within the first MAX_SCAN bytes are scanned; a hostile
  # page can't push work past the cap. Placed at the exact boundary so the guard is sharp.
  it "extracts hrefs before the MAX_SCAN cap but not after it" do
    before = %(<a href="/before">)
    after = %(<a href="/after">)
    pad = " " * (E::MAX_SCAN - before.bytesize) # before + pad == exactly MAX_SCAN bytes
    body = (before + pad + after).to_slice
    body.size.should be > E::MAX_SCAN # the /after token lives beyond the cap
    links = html_hrefs(body)
    links.should contain("/before")
    links.should_not contain("/after")
  end

  # (2)(3)(4) from_robots: the Sitemap: branch, the glob/comment trim (up to whitespace or '*'),
  # and skipping of lines with no colon / an empty value. Whole-array assert (order preserved).
  it "extracts robots Sitemap URLs, trims globs/comments, and skips junk lines" do
    body = <<-ROBOTS.to_slice
      Sitemap: http://h/sitemap.xml
      Disallow: /admin/* # comment
      NoColonLine here
      Disallow:
      Allow: /ok
      ROBOTS
    E.from_robots(body).should eq(["http://h/sitemap.xml", "/admin/", "/ok"])
  end

  it "trims a Disallow glob at the first '*' and a trailing comment at whitespace" do
    E.from_robots("Disallow: /admin/* # comment\n".to_slice).should eq(["/admin/"])
    E.from_robots("Disallow: /path # note\n".to_slice).should eq(["/path"])
    E.from_robots("Sitemap: http://h/sitemap.xml\n".to_slice).should eq(["http://h/sitemap.xml"])
  end

  it "skips robots lines with no colon or an empty value" do
    E.from_robots("this line has no colon\n".to_slice).should be_empty
    E.from_robots("Disallow:\n".to_slice).should be_empty     # empty value
    E.from_robots("Disallow:   \n".to_slice).should be_empty  # whitespace-only value
    E.from_robots("User-agent: *\n".to_slice).should be_empty # not a disallow/allow/sitemap key
  end

  # (5) from_html: an empty attribute value adds nothing (v && !v.empty?); a bare unquoted value
  # is captured via the third alternation group.
  it "skips an empty href but captures a bare unquoted src" do
    body = %(<a href="">empty</a> <script src=foo.js></script>).to_slice
    html_hrefs(body).should eq(["foo.js"])
  end

  it "captures bare unquoted href / action values (third regex group)" do
    html_hrefs(%(<a href=/plain.html>).to_slice).should eq(["/plain.html"])
    html_hrefs(%(<form action=submit.php>).to_slice).should eq(["submit.php"])
  end

  # (6) from_sitemap treats a <sitemapindex> child <loc> exactly like a <urlset> page <loc>.
  it "extracts sitemapindex child locs like urlset page locs" do
    index = %(<sitemapindex><sitemap><loc>http://h/child.xml</loc></sitemap></sitemapindex>).to_slice
    urlset = %(<urlset><url><loc>http://h/page.xml</loc></url></urlset>).to_slice
    E.from_sitemap(index).should eq(["http://h/child.xml"])
    E.from_sitemap(urlset).should eq(["http://h/page.xml"])
  end

  # (7) sitemap_body? sniffs only the first SNIFF_MAX bytes, and scrubs invalid UTF-8 (no raise).
  it "returns false when the sitemap root sits beyond SNIFF_MAX" do
    junk = "x" * E::SNIFF_MAX # non-matching leading junk exactly filling the sniff window
    body = (junk + %(<urlset><url><loc>http://h/p</loc></url></urlset>)).to_slice
    E.sitemap_body?(body).should be_false
    # sanity: with the root inside the window it is detected.
    E.sitemap_body?((junk[0, 10] + "<urlset>").to_slice).should be_true
  end

  it "scrubs invalid UTF-8 bytes before the root instead of raising" do
    io = IO::Memory.new
    io.write(Bytes[0xff, 0xfe, 0x80, 0xc0]) # invalid UTF-8 lead bytes
    io << %(<urlset><url><loc>http://h/p</loc></url></urlset>)
    E.sitemap_body?(io.to_slice).should be_true
  end

  # `sitemap_body?` runs a byte prefilter before it will build a String, so that the common
  # answer — "no", on every image, font and archive a spider follows — costs no allocation and
  # no PCRE2. The prefilter carries the LITERALS only; the `\b` stays with the regex, which
  # reads it with Unicode semantics (`<locé` is not a match, `<loc ` is). This pins the
  # two against each other: the shipped predicate must agree, body for body, with running
  # SITEMAP_ROOT over the sniff window directly.
  it "answers exactly what the sitemap regex answers, prefilter or not" do
    oracle = ->(body : Bytes) do
      slice = body.size > E::SNIFF_MAX ? body[0, E::SNIFF_MAX] : body
      String.new(slice).scrub.matches?(E::SITEMAP_ROOT)
    end

    bodies = [
      # the real shapes
      %(<?xml version="1.0"?><urlset><url><loc>http://h/p</loc></url></urlset>),
      %(<sitemapindex><sitemap><loc>http://h/s.xml</loc></sitemap></sitemapindex>),
      %(<URLSET><URL><LOC>http://h/p</LOC></URL></URLSET>), # the `i` flag
      %(<UrlSet >), %(<Loc\t>), %(<sitemapINDEX\n>),
      # literal present, boundary absent — the prefilter says maybe, the regex says no
      %(<location>a</location>), %(<locale lang="en">), %(<urlsets>), %(<sitemapindexes>),
      %(<locé>), %(<loc_id>), %(<loc0>),
      # literal absent — the prefilter alone decides
      %(<html><body><a href="/loc">not a sitemap</a></body></html>),
      %(<html><urlsetx</html>), %(no angle brackets at all: urlset loc sitemapindex),
      "User-agent: *\nDisallow: /admin\n", "", "<", "<l", "<lo", "<loc", "<urlse",
      # the literal split across the end of the sniff window
      ("y" * (E::SNIFF_MAX - 2)) + "<loc>", ("y" * (E::SNIFF_MAX - 5)) + "<loc>",
    ].map(&.to_slice)

    # …plus bodies that are not valid UTF-8, where the regex only ever sees the scrubbed form.
    binaries = [
      Bytes[0xff, 0xfe, 0x3c, 0x6c, 0x6f, 0x63, 0x3e],      # <loc> behind invalid lead bytes
      Bytes[0x3c, 0x6c, 0x6f, 0x63, 0xff, 0x3e],            # <loc followed by an invalid byte
      Bytes[0x3c, 0x4c, 0x4f, 0x43, 0xc0, 0x80],            # <LOC + an overlong sequence
      Bytes.new(2048) { |i| ((i * 7) % 251).to_u8 },        # an "image"
      Bytes.new(E::SNIFF_MAX + 64) { |i| (i % 256).to_u8 }, # larger than the sniff window
    ]

    (bodies + binaries).each do |body|
      E.sitemap_body?(body).should eq(oracle.call(body))
    end
  end

  # The scrub is only reached for a body that is ACTUALLY invalid: `String#scrub` walks the
  # whole string through a Char::Reader whether or not it finds anything (130µs on a valid
  # 40 KB page against 9µs for `valid_encoding?`), and EVERY crawled page and probe response
  # pays that, so `Extract.text` asks the cheap question first. This pins both branches — a
  # guard that skipped the scrub on an invalid body would raise `ArgumentError` from PCRE2.
  it "extracts links from a body with invalid UTF-8 in it, on every extractor" do
    bad = Bytes[0xff, 0xfe, 0x80, 0xc0]
    html = IO::Memory.new
    html.write(bad)
    html << %(<a href="/ok">x</a>)
    html_hrefs(html.to_slice).should eq(["/ok"])

    robots = IO::Memory.new
    robots.write(bad)
    robots << "\nDisallow: /admin\n"
    E.from_robots(robots.to_slice).should eq(["/admin"])

    sitemap = IO::Memory.new
    sitemap.write(bad)
    sitemap << %(<urlset><url><loc>http://h/p</loc></url></urlset>)
    E.from_sitemap(sitemap.to_slice).should eq(["http://h/p"])
  end

  # ── from_text: the endpoints no markup mentions ────────────────────────────────────────
  #
  # The branch that used to be `EMPTY_LINKS`. The spider fetches `<script src>` like any other
  # link; before this, it decoded and fingerprinted the bundle and then discarded every route
  # in it, so an API reachable only from JS was invisible to BOTH halves of the engine.
  it "extracts quoted root-relative paths and absolute URLs from a script bundle" do
    body = <<-JS.to_slice
      const API="/api/v2";
      fetch("/api/v2/cart",{method:"POST"});
      axios.get('/account/orders');
      import("https://cdn.acme.test/chunks/checkout.js");
      JS
    links = E.from_text(body)
    links.should contain("/api/v2")
    links.should contain("/api/v2/cart")
    links.should contain("/account/orders")
    links.should contain("https://cdn.acme.test/chunks/checkout.js")
  end

  # A `.well-known/` document's whole value is the URLs it lists, and every one of them is a
  # JSON string — the same shape from_text already looks for.
  it "extracts the endpoint URLs from an OIDC discovery document" do
    body = %({"issuer":"https://acme.test","token_endpoint":"https://acme.test/oauth2/token",\
"jwks_uri":"https://acme.test/oauth2/keys","registration_endpoint":"https://acme.test/connect/register"}).to_slice
    links = E.from_text(body)
    links.should contain("https://acme.test/oauth2/token")
    links.should contain("https://acme.test/oauth2/keys")
    links.should contain("https://acme.test/connect/register")
  end

  # An interpolated route has no closing quote and the class stops at `$`, which is why the
  # match does not require one: the DIRECTORY is exactly what the brute-forcer wants from it.
  it "yields the containing directory of an interpolated template-literal route" do
    E.from_text("fetch(`/api/users/${id}/roles`)".to_slice).should contain("/api/users/")
  end

  # The quote is the whole false-positive filter. Without it every division, regex literal and
  # date in a minified bundle would enter the frontier as a path.
  it "does not mistake regex literals, MIME types, dates or a bare slash for endpoints" do
    E.from_text(%(var re=/foo/g; var t="application/json"; var d="2026-07-19"; var s="/";).to_slice)
      .should be_empty
  end

  it "de-duplicates repeated endpoints within one body" do
    body = (%(fetch("/api/ping");) * 50).to_slice
    E.from_text(body).should eq(["/api/ping"])
  end

  # `consider_link` costs the ORCHESTRATOR fiber a resolve + parse + two keys per entry, so no
  # single response may hand it an unbounded list (see MAX_LINKS).
  it "caps one body at MAX_LINKS distinct endpoints" do
    body = (0..(E::MAX_LINKS + 500)).map { |i| %(f("/r#{i}");) }.join.to_slice
    E.from_text(body).size.should eq(E::MAX_LINKS)
  end

  # The cap is per BODY, so every pass `from_html` runs has to honour it — the meta-refresh
  # loop appends to the same accumulator the attribute loop filled.
  it "caps a body whose links arrive through more than one pass" do
    body = String.build do |s|
      (0..E::MAX_LINKS).each { |i| s << %(<a href="/a#{i}">x</a>) }
      (0..200).each { |i| s << %(<meta http-equiv="refresh" content="0;url=/m#{i}">) }
    end.to_slice
    html_hrefs(body).size.should eq(E::MAX_LINKS)
  end

  # An un-quoted `http://` in a minified bundle: the URL branch's class ends at whitespace and
  # quotes and at nothing else, so an unbounded `+` let one match run to the end of the scanned
  # body (up to MAX_SCAN, 2 MiB) and carried that whole string through resolve/parse/@seen.
  it "bounds a single URL match instead of letting it run to the end of the body" do
    body = ("http://t/a" + ("x" * 9000) + " end").to_slice
    urls = E.from_text(body)
    urls.size.should eq(1)
    # 2048 bounds the class AFTER the scheme, so the whole match is `http://` + 2048.
    urls.first.bytesize.should eq("http://".bytesize + 2048)
    urls.first.should start_with("http://t/a")
  end

  # ── from_html: inline script + the wider attribute set ─────────────────────────────────
  it "extracts endpoints out of an inline script as well as out of attributes" do
    body = %(<a href="/about">a</a><script>fetch("/api/v2/session");</script>).to_slice
    links = html_hrefs(body)
    links.should contain("/about")
    links.should contain("/api/v2/session")
  end

  it "de-duplicates an href the inline endpoint pass finds again" do
    body = %(<a href="/about">a</a><script>go("/about");</script>).to_slice
    html_hrefs(body).should eq(["/about"])
  end

  it "extracts poster and data-url attributes alongside href/src/action" do
    body = %(<video poster="/thumb.jpg"><div data-url="/api/lazy">).to_slice
    links = html_hrefs(body)
    links.should contain("/thumb.jpg")
    links.should contain("/api/lazy")
  end

  # `data-src` / `data-href` / `formaction` need no alternative of their own: the alternation
  # carries no word boundary, so they already match through `src` / `href` / `action`. Pinned
  # because a future "tighten the regex with \b" would silently drop three real sources.
  it "still captures data-src, data-href and formaction through the unanchored alternation" do
    links = html_hrefs(%(<img data-src="/lazy.png"><a data-href="/x"><button formaction="/submit">).to_slice)
    links.should contain("/lazy.png")
    links.should contain("/x")
    links.should contain("/submit")
  end

  # srcset's value is a `url 1x, url 2x` descriptor list, not one URL, so ATTR deliberately
  # does not match it — capturing it whole would hand `Url.resolve` a string it percent-encodes
  # into a URL nobody serves. The endpoint pass then picks the first entry out of it correctly,
  # because its character class ends at the descriptor's space. Pinned in that shape: what must
  # never appear is the joined `/a.png 1x, /b.png 2x`.
  it "takes a real URL out of a srcset rather than its whole descriptor list" do
    html_hrefs(%(<img srcset="/a.png 1x, /b.png 2x">).to_slice).should eq(["/a.png"])
  end

  # (8) Adversarial regex regression guard (spec/fuzz_spec.cr style): a long unclosed
  # <meta ... url= with a multi-KB attribute value must complete and RETURN (from_html does not
  # rescue Regex::Error, so a hang → harness timeout and a raise → spec failure). NOT a known-vuln claim.
  it "handles a long unclosed meta/attr body in bounded time (backtracking guard)" do
    evil = ("<meta http-equiv=\"refresh\" content=\"" + ("url= " * 100_000)).to_slice
    html_hrefs(evil).should be_a(Array(String)) # returned, did not hang or raise
    # a giant bare unquoted src value ([^\s"'>]+) is linear, not pathological
    big = ("<img src=" + ("a" * 500_000)).to_slice
    html_hrefs(big).should eq(["a" * 500_000])
  end

  # ── declared vs inferred ────────────────────────────────────────────────────────────────
  # The bit `Engine#consider_link` spends hundreds of requests on. A URL the markup NAMED as a
  # link is the target's own statement that something is there; a quoted string in a script that
  # happens to look like a path is a pattern match on text, and a locale key or an asset manifest
  # entry looks exactly the same.
  describe "Found#declared" do
    it "marks attribute and meta-refresh links declared, and script literals inferred" do
      body = %(<a href="/about">x</a>\
<meta http-equiv="refresh" content="0; url=/next">\
<script>fetch("/api/v2/cart")</script>).to_slice
      by_href = E.from_html(body).to_h { |f| {f.href, f.declared} }
      by_href["/about"].should be_true
      by_href["/next"].should be_true
      by_href["/api/v2/cart"].should be_false
    end

    # Precedence: the attribute passes run first and share `seen` with the endpoint pass, so a URL
    # that appears BOTH ways keeps the stronger classification instead of the later one winning.
    it "keeps a url declared when it is also present as a script literal" do
      body = %(<a href="/dash">x</a><script>go("/dash")</script>).to_slice
      found = E.from_html(body)
      found.count { |f| f.href == "/dash" }.should eq(1)
      found.find { |f| f.href == "/dash" }.not_nil!.declared.should be_true
    end

    # A body that is not markup declares nothing at all — the caller tags the whole list inferred,
    # which is why this returns bare strings.
    it "returns plain strings from from_text, which are inferred by construction" do
      E.from_text(%(fetch("/api/ping")).to_slice).should eq(["/api/ping"])
    end
  end

  # `base_href` is not one candidate link among many: `Engine#expand_links` resolves EVERY
  # relative href on the page against it, so a `<base>` read out of a comment or a script
  # relocates the entire crawl. A commented-out `<base href="/old/">` left in a template made
  # gori request `/old/`, `/old/page1` and `/old/?page=2` and never request the `/page1` that
  # actually answers 200.
  describe ".base_href" do
    it "reads a real document base out of the head" do
      E.base_href(%(<html><head><base href="/app/"></head><body><a href="x">x</a></body></html>).to_slice)
        .should eq("/app/")
      # Single quotes, bare values and a `<base target>` carrying no href all still work.
      E.base_href(%(<base target="_blank"><base href='/q/'>).to_slice).should eq("/q/")
      E.base_href(%(<base href=/bare/>).to_slice).should eq("/bare/")
    end

    it "ignores a <base> inside an HTML comment" do
      body = %(<html><head>\n<!-- legacy: <base href="/old/"> -->\n</head>) +
             %(<body><a href="page1">page1</a></body></html>)
      E.base_href(body.to_slice).should be_nil
    end

    # The comment must not swallow the REAL base that follows it, either.
    it "still finds the real base after a commented-out one" do
      body = %(<head><!-- <base href="/old/"> --><base href="/new/"></head>)
      E.base_href(body.to_slice).should eq("/new/")
    end

    it "ignores a <base> inside script / style / textarea / title text" do
      E.base_href(%(<head><script>var t = '<base href="/js/">';</script></head>).to_slice).should be_nil
      E.base_href(%(<head><style>/* <base href="/css/"> */</style></head>).to_slice).should be_nil
      E.base_href(%(<head><title><base href="/t/"></title></head>).to_slice).should be_nil
      E.base_href(%(<body><textarea><base href="/ta/"></textarea></body>).to_slice).should be_nil
      # …and the element's own close must be the one that ends it.
      E.base_href(%(<head><script>x = "</style>"; y = '<base href="/js/">';</script></head>).to_slice)
        .should be_nil
    end

    it "does not read a <base> that comes after the head" do
      E.base_href(%(<head></head><body><base href="/late/"></body>).to_slice).should be_nil
      E.base_href(%(<html><body><base href="/late/">).to_slice).should be_nil
    end

    # A `</head>` or `<body` written inside a comment is not markup, so it cannot end the head
    # early and hide the base that follows it.
    it "does not let a commented-out </head> cut the head short" do
      E.base_href(%(<head><!-- </head><body> --><base href="/real/"></head>).to_slice)
        .should eq("/real/")
    end

    # An unterminated comment masks the rest of the document, exactly as a browser's parser
    # does — the base inside it is never a base.
    it "treats an unclosed comment as running to the end" do
      E.base_href(%(<head><!-- oops <base href="/never/">).to_slice).should be_nil
    end

    # An ORPHAN closing tag is not the end of the head. `HEAD_TOKEN` matches `</script>`,
    # `</style>`, `</textarea>` and `</title>` whether or not the matching opener was ever
    # seen, and with no raw-text element open the walk had nothing left to do with one but
    # fall through to the `<body` / `</head` arm and cut the head there. Everything after the
    # orphan — the `<base href>` included — was then past `cut` and refused, so
    # `Engine#expand_links` resolved the whole page against the wrong base and the crawl
    # walked into a directory that answers nothing. That is the same whole-page false negative
    # the region walk was added to close, arriving from the opposite side.
    #
    # All four, separately, because each is a page shape that really occurs: a template engine
    # emitting a closing tag whose opener sat in a conditional branch that did not render, a
    # head partial included on its own so its `</title>` arrives before anything opened one,
    # a CMS field pasted into the head with a closer left in it.
    it "does not let an unpaired closing raw-text tag cut the head short" do
      E.base_href(%(<head></script><base href="/app/"></head>).to_slice).should eq("/app/")
      E.base_href(%(<head></style><base href="/app/"></head>).to_slice).should eq("/app/")
      E.base_href(%(<head></textarea><base href="/app/"></head>).to_slice).should eq("/app/")
      E.base_href(%(<head></title><base href="/app/"></head>).to_slice).should eq("/app/")
    end

    # The template-conditional shape as it actually ships, with real markup around it rather
    # than the orphan on its own: `{% if debug %}<script>…{% endif %}</script>` renders the
    # closer and not the opener, and everything downstream of it used to become unreachable.
    it "finds the base and the links after a template leaves a closer unpaired" do
      body = %(<html><head><meta charset="utf-8"></script>) +
             %(<base href="/app/"><script src="/real.js"></script></head>) +
             %(<body><a href="page1">p</a></body></html>)
      E.base_href(body.to_slice).should eq("/app/")
    end

    # A stray `-->` with no comment open is the same defect wearing the other token: HTML
    # treats it as text, and the walk treated it as the end of the head.
    it "does not let a stray comment close cut the head short" do
      E.base_href(%(<head>--><base href="/app/"></head>).to_slice).should eq("/app/")
    end

    # …and the fix must not have bought that by making orphans invisible to the state machine.
    # A PAIRED raw-text element still masks its contents, `<body` / `</head` still end the
    # head, and an unclosed one still runs to the end.
    it "still ignores a base inside a properly paired element after an orphan close" do
      E.base_href(%(<head></script><script><base href="/js/"></script></head>).to_slice).should be_nil
      E.base_href(%(<head></title><!-- <base href="/old/"> --></head>).to_slice).should be_nil
      E.base_href(%(<head></script></head><body><base href="/late/"></body>).to_slice).should be_nil
      E.base_href(%(<head></style><title><base href="/t/">).to_slice).should be_nil
    end

    # `<base href="">` is legal HTML meaning "the page URL", and it is still the FIRST base:
    # HTML 4.2.3 ignores every one after it, so a later one must not be picked up instead.
    it "keeps first-match-only semantics, empty value included" do
      E.base_href(%(<head><base href=""><base href="/second/"></head>).to_slice).should be_nil
      E.base_href(%(<head><base href="/first/"><base href="/second/"></head>).to_slice)
        .should eq("/first/")
    end

    it "answers nil for a body with no base at all" do
      E.base_href(%(<html><head><title>hi</title></head><body><a href="/a">a</a></body>).to_slice)
        .should be_nil
      E.base_href(Bytes.empty).should be_nil
    end

    # Same contract as every other extractor here: the scan runs over the scrubbed text.
    it "reads a base out of a body that is not valid UTF-8" do
      io = IO::Memory.new
      io.write(Bytes[0xff, 0xfe, 0x80])
      io << %(<head><base href="/ok/"></head>)
      E.base_href(io.to_slice).should eq("/ok/")
    end
  end
end
