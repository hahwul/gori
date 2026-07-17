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
end
