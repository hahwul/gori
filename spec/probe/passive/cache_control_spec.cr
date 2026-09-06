require "../../spec_helper"

describe Gori::Probe::Passive::CacheControl do
  it "combines every physical Cache-Control field in wire order" do
    headers = Gori::Proxy::Codec::HeaderList.new([
      Gori::Proxy::Codec::Header.new("Cache-Control", "private, max-age=60"),
      Gori::Proxy::Codec::Header.new("X-Other", "ignored"),
      Gori::Proxy::Codec::Header.new("cache-control", "public, s-maxage=120"),
    ])

    Gori::Probe::Passive::CacheControl.parse(headers).should eq([
      "private", "max-age=60", "public", "s-maxage=120",
    ])
  end

  it "does not promote words inside a quoted extension argument to directives" do
    parts = Gori::Probe::Passive::CacheControl.parse(
      %(note="public, no-store", max-age="60"))

    Gori::Probe::Passive::CacheControl.directive?(parts, "public").should be_false
    Gori::Probe::Passive::CacheControl.directive?(parts, "no-store").should be_false
    Gori::Probe::Passive::CacheControl.int(parts, "max-age").should eq(60)
  end

  it "matches directive names exactly while tolerating OWS before equals" do
    parts = Gori::Probe::Passive::CacheControl.parse(
      "public-ish, x-no-store, max-age\t=\t30")

    Gori::Probe::Passive::CacheControl.directive?(parts, "public").should be_false
    Gori::Probe::Passive::CacheControl.directive?(parts, "no-store").should be_false
    Gori::Probe::Passive::CacheControl.int(parts, "max-age").should eq(30)
  end
end
