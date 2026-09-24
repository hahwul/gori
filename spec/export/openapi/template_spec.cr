require "../../spec_helper"

private alias TPL = Gori::Export::OpenApi::Template

describe Gori::Export::OpenApi::Template do
  it "templates numeric, uuid, hex and date segments, naming each after the segment before it" do
    r = TPL.of("/users/123/orders/3f1c9ab4-0000-4000-8000-00000000abcd/reports/2026-07-19")
    r.path.should eq("/users/{userId}/orders/{orderId}/reports/{reportId}")
    r.params.map { |p| {p.name, p.kind, p.prev} }.should eq([
      {"userId", TPL::Kind::Integer, "users"}, {"orderId", TPL::Kind::Uuid, "orders"},
      {"reportId", TPL::Kind::Date, "reports"},
    ])
    r.params.map(&.raw).should eq(["123", "3f1c9ab4-0000-4000-8000-00000000abcd", "2026-07-19"])
    TPL.of("/blobs/9f1c2b7d0a4e").path.should eq("/blobs/{blobId}")
  end

  # OpenAPI forbids two templated paths that differ only in parameter NAMES, so a name comes
  # from the position and never from what the value looked like.
  it "names a parameter by position, whatever kind of value filled it" do
    TPL.of("/reports/2026-07-19").path.should eq(TPL.of("/reports/123").path)
  end

  it "templates credential-shaped segments, so a path key never carries a token" do
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXBhcnQ"
    TPL.of("/reset/#{jwt}").path.should eq("/reset/{resetId}")
    TPL.of("/services/T0A1/B0B2/Xk9fQ2mLp8RtZ7vW3yN1").path.should eq("/services/T0A1/B0B2/{b0B2Id}")
    TPL.of("/blog/rust-and-crystal-in-2026").path.should eq("/blog/rust-and-crystal-in-2026") # a slug is lower case
    # A camelCase RPC route is a route: two of them must not merge into one `{apiId}`.
    TPL.of("/api/getUserProfileV2").path.should eq("/api/getUserProfileV2")
    TPL.of("/api/getAccountInfoV3").path.should eq("/api/getAccountInfoV3")
    TPL.of("/login;jsessionid=ABCDEF0123456789XYZ").path.should eq("/login")
    TPL.of("/a;v=1/b").path.should eq("/a/b")
    TPL.of("/a;b").path.should eq("/a;b") # no `=`: not a matrix parameter
  end

  it "names a parameter after a non-UTF-8 segment without raising" do
    TPL.of("/caf#{String.new(Bytes[0xE9])}/123").path.should eq("/caf%E9/{cafId}")
  end

  it "templates a single captured numeric id — unlike the Sitemap's display fold" do
    TPL.of("/users/123").path.should eq("/users/{userId}")
  end

  it "keeps names unique within a path, the date case included" do
    TPL.of("/r/2026-07-19/2026-07-20").path.should eq("/r/{rId}/{id}")
    TPL.of("/x/1/2/3").path.should eq("/x/{xId}/{id}/{id2}")
    TPL.of("/1/2").path.should eq("/{id}/{id2}")
    TPL.of("/users/1/users/2").path.should eq("/users/{userId}/users/{userId2}")
  end

  it "derives names from multi-word and plural segments" do
    TPL.of("/user-groups/5").path.should eq("/user-groups/{userGroupId}")
    TPL.of("/categories/5").path.should eq("/categories/{categoryId}")
    TPL.of("/addresses/5").path.should eq("/addresses/{addressId}")
    TPL.of("/status/5").path.should eq("/status/{statusId}")
    TPL.of("/ids/5").path.should eq("/ids/{id}")
    TPL.of("/%E4%B8%AD/5").path.should eq("/%E4%B8%AD/{id}") # an escape's hex digits are not a word
    TPL.of("/9x/5").path.should eq("/9x/{id}")               # an identifier cannot open with a digit
  end

  it "leaves a date that is not a real date, and short hex, literal" do
    TPL.of("/r/2026-13-40").path.should eq("/r/2026-13-40")
    TPL.of("/r/abc123").path.should eq("/r/abc123")
    TPL.of("/v2/users").path.should eq("/v2/users")
  end

  it "maps the root and keeps an interior empty segment" do
    TPL.of("/").path.should eq("/")
    TPL.of("/a//b").path.should eq("/a//b")
  end

  it "percent-encodes what a path key cannot carry, keeping existing escapes" do
    TPL.literal("{id}").should eq("%7Bid%7D")
    TPL.literal("a b").should eq("a%20b")
    TPL.literal("%41x").should eq("%41x")
    TPL.literal("100%").should eq("100%25")
    TPL.literal("é").should eq("%C3%A9")
    TPL.literal(String.new(Bytes[0x61, 0xff])).should eq("a%FF") # invalid UTF-8 is escaped, not raised on
    TPL.literal("a:b@c").should eq("a:b@c")
  end
end
