require "../spec_helper"

describe Gori::Oast::HttpClient do
  it "turns URI parser failures into a provider error" do
    client = Gori::Oast::HttpClient.new

    ["http://oast.test:abc/", "http://oast.test:99999999999/"].each do |url|
      expect_raises(Gori::Error, /OAST: invalid URL/) do
        client.request("GET", url)
      end
    end
  end
end
