require "./spec_helper"

describe Gori::Env do
  it "expands registered keys and leaves unknown keys literal" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [{"HOST", "api.test"}, {"TOKEN", "secret"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    Gori::Env.expand("GET http://$HOST/path HTTP/1.1\nAuth: $TOKEN\nX: $MISSING").should eq(
      "GET http://api.test/path HTTP/1.1\nAuth: secret\nX: $MISSING")
  ensure
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.env_prefix = "$"
    Gori::Settings.project_env_vars = [] of {String, String}
  end

  it "lets project vars override global vars" do
    Gori::Settings.env_vars = [{"HOST", "global.test"}]
    Gori::Settings.project_env_vars = [{"HOST", "project.test"}]
    Gori::Env.expand("$HOST").should eq("project.test")
  ensure
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
  end

  it "parses KEY VALUE and KEY=value lines" do
    Gori::Env.parse_line("HOST api.example.com").should eq({"HOST", "api.example.com"})
    Gori::Env.parse_line("TOKEN=abc def").should eq({"TOKEN", "abc def"})
    Gori::Env.parse_line("bad-key x").should be_nil
  end

  it "token_regions marks known vs unknown" do
    Gori::Settings.env_vars = [{"HOST", "h"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    regions = Gori::Env.token_regions("http://$HOST/$OTHER")
    regions.should eq([{7, 12, true}, {13, 19, false}])
  ensure
    Gori::Settings.env_vars = [] of {String, String}
  end
end
