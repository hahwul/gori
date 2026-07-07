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

  it "expand_wire normalizes both LF and already-CRLF input to single CRLF" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    # already-CRLF wire bytes (captured flow) must NOT double to \r\r\n
    crlf = "GET / HTTP/1.1\r\nHost: x\r\n\r\nbody"
    String.new(Gori::Env.expand_wire(crlf)).should eq(crlf)
    # LF-only input is upgraded to CRLF
    lf = "GET / HTTP/1.1\nHost: x\n\nbody"
    String.new(Gori::Env.expand_wire(lf)).should eq(crlf)
  ensure
    Gori::Settings.env_prefix = "$"
  end

  it "mask_secrets does not corrupt a token an earlier replacement inserted" do
    # ABCD's value contains Q's KEY name; a sequential gsub would mangle it to "$$Q".
    vars = {"ABCD" => "s3cr3tXY", "Q" => "ABCD"}
    masked = Gori::Env.mask_secrets("token=s3cr3tXY here", vars, "$")
    masked.should eq("token=$ABCD here")
    # and it round-trips back through expand
    Gori::Env.expand(masked, vars, "$").should eq("token=s3cr3tXY here")
  end

  it "mask_secrets prefers the longest value at each position" do
    vars = {"SHORT" => "secret", "LONG" => "secret_value"}
    Gori::Env.mask_secrets("x=secret_value", vars, "$").should eq("x=$LONG")
    Gori::Env.mask_secrets("x=secret!", vars, "$").should eq("x=$SHORT!")
  end
end
