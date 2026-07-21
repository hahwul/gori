require "../spec_helper"

private alias E = Gori::Discover::Extract

describe Gori::Discover::Extract do
  it "extracts href / src / action links from html" do
    body = %(<a href="/a">x</a> <img src='/b.png'> <form action="/submit"> <link href=/style.css>).to_slice
    links = E.from_html(body)
    links.should contain("/a")
    links.should contain("/b.png")
    links.should contain("/submit")
    links.should contain("/style.css")
  end

  it "extracts a meta-refresh url" do
    body = %(<meta http-equiv="refresh" content="0; url=/next-page">).to_slice
    E.from_html(body).should contain("/next-page")
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
    links = E.from_html(body)
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
    E.from_html(body).should eq(["foo.js"])
  end

  it "captures bare unquoted href / action values (third regex group)" do
    E.from_html(%(<a href=/plain.html>).to_slice).should eq(["/plain.html"])
    E.from_html(%(<form action=submit.php>).to_slice).should eq(["submit.php"])
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

  # (8) Adversarial regex regression guard (spec/fuzz_spec.cr style): a long unclosed
  # <meta ... url= with a multi-KB attribute value must complete and RETURN (from_html does not
  # rescue Regex::Error, so a hang → harness timeout and a raise → spec failure). NOT a known-vuln claim.
  it "handles a long unclosed meta/attr body in bounded time (backtracking guard)" do
    evil = ("<meta http-equiv=\"refresh\" content=\"" + ("url= " * 100_000)).to_slice
    E.from_html(evil).should be_a(Array(String)) # returned, did not hang or raise
    # a giant bare unquoted src value ([^\s"'>]+) is linear, not pathological
    big = ("<img src=" + ("a" * 500_000)).to_slice
    E.from_html(big).should eq(["a" * 500_000])
  end
end
