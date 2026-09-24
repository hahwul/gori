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
        "image/svg+xml", "image/svg+xml; charset=utf-8", "text/css", "application/javascript",
        "text/javascript", "application/json", "application/pdf", "application/zip",
        "application/octet-stream", "application/wasm", "text/html",
      }.each do |ct|
        Gori::StaticAsset.static?(ct, "/logo.png", 200).should be_false
      end
    end

    it "never calls an error static, so a 404 on /logo.png stays visible" do
      Gori::StaticAsset.static?("image/png", "/logo.png", 404).should be_false
      Gori::StaticAsset.static?(nil, "/logo.png", 500).should be_false
      Gori::StaticAsset.static?("image/png", "/logo.png", 399).should be_true
    end

    it "falls back to the path's extension when there is no Content-Type (a 304, a pending row)" do
      Gori::StaticAsset.static?(nil, "/img/logo.PNG", 304).should be_true
      Gori::StaticAsset.static?("", "/f/inter.woff2?v=3", 304).should be_true
      Gori::StaticAsset.static?(nil, "/clip.mp4#t=10", nil).should be_true
      Gori::StaticAsset.static?(nil, "http://a.test/logo.png", nil).should be_true
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
