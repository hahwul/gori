require "./spec_helper"

describe Gori::StaticAsset do
  describe ".static?" do
    it "hides images, fonts and media by their response MIME" do
      {
        "image/png", "IMAGE/JPEG", "image/webp; charset=binary", " image/gif ",
        "font/woff2", "application/font-woff", "application/x-font-ttf",
        "application/vnd.ms-fontobject", "audio/mpeg", "video/mp4",
      }.each do |ct|
        Gori::StaticAsset.static?(ct, "/x", 200).should be_true
      end
    end

    it "keeps everything that can carry an endpoint, a secret or script" do
      {
        "image/svg", "image/svgz", "image/svg+xml", "image/svg+xml; charset=utf-8", "text/css", "application/javascript",
        "text/javascript", "application/json", "application/pdf", "application/zip",
        "application/octet-stream", "application/wasm", "text/html",
        "audio/mpegurl", "audio/x-mpegurl", # HLS/M3U playlists: a list of URLs
      }.each do |ct|
        Gori::StaticAsset.static?(ct, "/logo.png", 200).should be_false
      end
    end

    it "calls only a successful fetch static — never an error, a redirect or no response" do
      Gori::StaticAsset.static?("image/png", "/logo.png", 404).should be_false
      Gori::StaticAsset.static?(nil, "/logo.png", 500).should be_false
      # 302 Location: /login on an asset path, with no Content-Type.
      Gori::StaticAsset.static?(nil, "/uploads/42.png", 302).should be_false
      # status 0 is gori's "no response": a dropped intercept, an upstream failure.
      Gori::StaticAsset.static?(nil, "/logo.png", 0).should be_false
      Gori::StaticAsset.static?("image/png", "/logo.png", 206).should be_true
    end

    it "keeps an image fetched through a URL parameter — an image proxy is an SSRF surface" do
      Gori::StaticAsset.static?("image/webp", "/_next/image?url=%2Fhero.jpg&w=640", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/thumb?src=https://evil.test/x.png", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/thumb?u=https%3A%2F%2Fevil.test", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/resize?src=//169.254.169.254/x.png", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/fetch?u=http%3A//10.0.0.1/", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/fetch?u=HTTP%3a//10.0.0.1/", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/fetch?u=http%3A%2F%2F10.0.0.1/", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/logo.png?v=3", 200).should be_true
    end

    it "keeps an image fetched through a URL embedded in the path" do
      Gori::StaticAsset.static?("image/jpeg", "/unsafe/300x200/https://internal.example/a.jpg", 200).should be_false
      Gori::StaticAsset.static?("image/jpeg", "/unsafe/300x200/https:/internal.example/a.jpg", 200).should be_false
      Gori::StaticAsset.static?("image/jpeg", "/unsafe/300x200/http:/internal.example/a.jpg", 200).should be_false
      Gori::StaticAsset.static?("image/jpeg", "/unsafe/https%3A/internal.example/a.jpg", 200).should be_false
      Gori::StaticAsset.static?("image/jpeg", "/unsafe/https%3A%2F%2Finternal.example/a.jpg", 200).should be_false
    end

    it "falls back to the path's extension when there is no Content-Type on a response" do
      Gori::StaticAsset.static?(nil, "/img/logo.PNG", 304).should be_true
      Gori::StaticAsset.static?("", "/f/inter.woff2?v=3", 304).should be_true
      Gori::StaticAsset.static?(nil, "http://a.test/logo.png", 304).should be_true
      Gori::StaticAsset.static?(nil, "/clip.mp4#t=10", nil).should be_false
      Gori::StaticAsset.static?(nil, "http://a.test/logo.png", nil).should be_false
    end

    it "reads the extension of the PATH, not of the query string" do
      Gori::StaticAsset.static?(nil, "/app.js?v=logo.png", 304).should be_false
      Gori::StaticAsset.static?(nil, "/api/items", nil).should be_false
      Gori::StaticAsset.static?(nil, "/style.css", 304).should be_false
      Gori::StaticAsset.static?(nil, "/app.js.map", 304).should be_false
      Gori::StaticAsset.static?(nil, "/backup.zip", 304).should be_false
      Gori::StaticAsset.static?(nil, "/.png", 304).should be_false
      Gori::StaticAsset.static?(nil, "/dir.png/", 304).should be_false
      Gori::StaticAsset.static?(nil, "", nil).should be_false
      Gori::StaticAsset.static?(nil, "a.test:443", nil).should be_false
    end

    it "trusts a present Content-Type over the extension" do
      Gori::StaticAsset.static?("application/json", "/avatar.png", 200).should be_false
      Gori::StaticAsset.static?("image/png", "/avatar", 200).should be_true
    end
  end

  describe "the hide-static setting" do
    it "defaults to off and persists per project" do
      with_store do |store|
        Gori::StaticAsset.hidden?(store).should be_false
        Gori::StaticAsset.set_hidden(store, true).should be_true
        Gori::StaticAsset.hidden?(store).should be_true
        Gori::StaticAsset.set_hidden(store, false).should be_true
        Gori::StaticAsset.hidden?(store).should be_false
      end
    end
  end

  it "keeps Discover's BINARY_EXT as the media set plus archives" do
    Gori::Discover::Url::BINARY_EXT.should eq(Gori::StaticAsset::MEDIA_EXT + Gori::StaticAsset::ARCHIVE_EXT)
    Gori::Discover::Url.binary_asset?("/a/b.zip").should be_true
    Gori::Discover::Url.binary_asset?("/a/b.png").should be_true
    Gori::Discover::Url.binary_asset?("/a/b.css").should be_false
  end
end
