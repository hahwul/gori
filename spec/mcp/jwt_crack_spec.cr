require "../spec_helper"

describe "MCP jwt_crack" do
  it "cracks line N of a saved list after inline candidates and reports a complete miss" do
    with_wordlist_home do |dir|
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "jwt-secrets.txt"), "first\ncustom-key\nlast\n")
      with_store do |store|
        tools = tools_for(store)
        token = Gori::Jwt.encode("{}", "{}", "HS384", "custom-key")
        args = JSON.parse({token: token, secrets: ["inline"], wordlist: "jwt-secrets.txt"}.to_json)
        r = tools.call("jwt_crack", args)
        r.is_error.should be_false
        j = JSON.parse(r.text)
        j["secret"].as_s.should eq("custom-key")
        j["tried"].as_i.should eq(3)
        miss = tools.call("jwt_crack", JSON.parse({token: Gori::Jwt.encode("{}", "{}", "HS384", "absent"), wordlist: "jwt-secrets.txt"}.to_json))
        JSON.parse(miss.text).as_h.should eq(JSON.parse(%({"found":false,"tried":3,"stopped":false})).as_h)
      end
    end
  end

  it "refuses non-HMAC tokens, absent candidates and transport/device wordlists" do
    with_store do |store|
      tools = tools_for(store)
      token = Gori::Jwt.encode("{}", "{}", "none", "")
      r = tools.call("jwt_crack", JSON.parse({token: token, secrets: ["x"]}.to_json))
      r.is_error.should be_true
      r.text.should contain("UNSIGNED")
      tools.call("jwt_crack", JSON.parse({token: token}.to_json)).is_error.should be_true
      %w[/dev/stdin /dev/zero].each do |path|
        tools.call("jwt_crack", JSON.parse({token: token, wordlist: path}.to_json)).is_error.should be_true
      end unless {% flag?(:win32) %}
    end
  end

  it "honors cancellation and remains an unbound read tool outside @recon" do
    tools = Gori::MCP::Tools.new(nil, false, false)
    token = Gori::Jwt.encode("{}", "{}", "HS256", "hit")
    r = tools.call("jwt_crack", JSON.parse({token: token, secrets: ["hit"]}.to_json), cancelled: -> { true })
    j = JSON.parse(r.text)
    j["stopped"].as_bool.should be_true
    j["tried"].as_i.should eq(0)
    catalogue = JSON.parse(Gori::MCP::Tools.catalogue_json(nil, false)).as_a
    t = catalogue.find! { |entry| entry["name"].as_s == "jwt_crack" }
    t["annotations"]["readOnlyHint"].as_bool.should be_true
    t["annotations"]["openWorldHint"].as_bool.should be_false
    recon = Gori::MCP::ToolFilter.parse("@recon", Gori::MCP::Tools::TOOL_NAMES, Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
    JSON.parse(Gori::MCP::Tools.catalogue_json(recon, true)).as_a.any? { |entry| entry["name"].as_s == "jwt_crack" }.should be_false
  end
end
