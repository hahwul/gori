require "../spec_helper"

describe "MCP cookie_crack cancellation" do
  it "stops after yielding in each format and keeps the existing result shape" do
    cookies = {
      "flask"  => Gori::Cookie::Flask.forge("{}", "hit", 0_i64),
      "rack"   => Gori::Cookie::Rack.forge("data", "hit"),
      "django" => Gori::Cookie::Django.forge("{}", "hit", 0_i64),
    }
    cookies.each do |format, cookie|
      tools = Gori::MCP::Tools.new(nil, false, false)
      secrets = Array.new(10_000, "wrong") << "hit"
      args = JSON.parse({cookie: cookie, secrets: secrets}.to_json)
      stop = false
      spawn { stop = true }
      result = tools.call("cookie_crack", args, cancelled: -> { stop })
      result.is_error.should be_false
      JSON.parse(result.text).as_h.should eq(JSON.parse({found: false, format: format}.to_json).as_h)
      complete = tools.call("cookie_crack", args)
      JSON.parse(complete.text).as_h.should eq(JSON.parse({found: true, secret: "hit", format: format}.to_json).as_h)
    end
  end
end
