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

  it "parse_line picks the space form when whitespace precedes the first '=' (value contains '=')" do
    # e.g. `gori run project env set APIKEY dGVzdA==` — the space form's value may
    # itself contain '=' (base64 padding); the FIRST separator to appear (the
    # space) decides the syntax, not whether '=' appears anywhere in the string.
    Gori::Env.parse_line("APIKEY dGVzdA==").should eq({"APIKEY", "dGVzdA=="})
    # '=' still wins when it comes first (unchanged KEY=value behavior).
    Gori::Env.parse_line("TOKEN=a=b c=d").should eq({"TOKEN", "a=b c=d"})
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

  it "expand passes invalid UTF-8 bytes through unchanged when there is no $ prefix at all" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    # 0x80 is a lone continuation byte; 0xE2 0x28 is a truncated/invalid 3-byte
    # lead — neither is valid UTF-8. Old `expand` rebuilt via `String#chars` and
    # silently replaced both with U+FFFD, growing the byte count.
    bad = Bytes[0x41, 0x80, 0x42, 0xE2, 0x28, 0x43]
    text = String.new(bad)
    Gori::Env.expand(text).to_slice.should eq(bad)
  ensure
    Gori::Settings.env_prefix = "$"
  end

  it "expand substitutes a known $KEY while leaving invalid UTF-8 bytes elsewhere untouched" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [{"TOKEN", "secret"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    bad_body = Bytes[0x41, 0x80, 0x42, 0xE2, 0x28, 0x43]
    raw = IO::Memory.new
    raw << "Auth: $TOKEN\r\n"
    raw.write(bad_body)
    text = String.new(raw.to_slice)

    result = Gori::Env.expand(text).to_slice
    result[0, "Auth: secret\r\n".bytesize].should eq("Auth: secret\r\n".to_slice)
    result[-bad_body.size, bad_body.size].should eq(bad_body)
  ensure
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.env_prefix = "$"
  end

  it "expand_wire does not raise and still normalizes CRLF when the text has invalid UTF-8" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    bad = Bytes[0x47, 0x45, 0x54, 0x0A, 0x80, 0x0A] # "GET" LF <invalid> LF
    text = String.new(bad)
    Gori::Env.expand_wire(text).should eq(Bytes[0x47, 0x45, 0x54, 0x0D, 0x0A, 0x80, 0x0D, 0x0A])
  ensure
    Gori::Settings.env_prefix = "$"
  end

  # Regression: normalize_crlf used to run over the WHOLE buffer (head + body), so a bare
  # 0x0A byte inside a binary/compressed BODY — not a line ending — got a spurious 0x0D
  # inserted in front of it. Silent corruption: Content-Length gets resynced to the
  # already-corrupted body afterward, so nothing downstream notices the mismatch. Only the
  # HEAD (through the blank-line separator) may be CRLF-normalized; the body must round-trip
  # byte-exact regardless of what bytes it contains.
  it "expand_wire leaves a bare LF byte in the BODY untouched (head-only CRLF normalization)" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    # LF-joined head (editor storage form) + a body with a bare LF, a lone CR, and an
    # already-CRLF pair — none of these body bytes are line endings and must survive as-is.
    text = "POST / HTTP/1.1\nHost: x\nContent-Length: 6\n\n" + String.new(Bytes[0x41, 0x0A, 0x42, 0x0D, 0x0A, 0x43])
    result = Gori::Env.expand_wire(text)
    expected_head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n\r\n".to_slice
    expected_body = Bytes[0x41, 0x0A, 0x42, 0x0D, 0x0A, 0x43] # unchanged: A LF B CR LF C
    result[0, expected_head.size].should eq(expected_head)
    result[expected_head.size, expected_body.size].should eq(expected_body)
    result.size.should eq(expected_head.size + expected_body.size)
  ensure
    Gori::Settings.env_prefix = "$"
  end

  it "expand_wire normalizes an already-CRLF head and leaves a bare-LF body untouched" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    # Already-CRLF head (e.g. captured flow bytes) — must not double to \r\r\n — followed
    # by a bare-LF body that must stay untouched.
    text = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n" + String.new(Bytes[0x41, 0x0A, 0x42])
    result = Gori::Env.expand_wire(text)
    expected_head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n".to_slice
    expected_body = Bytes[0x41, 0x0A, 0x42]
    result[0, expected_head.size].should eq(expected_head)
    result[expected_head.size, expected_body.size].should eq(expected_body)
    result.size.should eq(expected_head.size + expected_body.size)
  ensure
    Gori::Settings.env_prefix = "$"
  end

  it "expand_wire substitutes a $KEY in the head while a bare-LF body stays untouched" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [{"TOKEN", "secret"}]
    Gori::Settings.project_env_vars = [] of {String, String}
    text = "POST / HTTP/1.1\nHost: x\nAuth: $TOKEN\nContent-Length: 3\n\n" + String.new(Bytes[0x41, 0x0A, 0x42])
    result = Gori::Env.expand_wire(text)
    expected_head = "POST / HTTP/1.1\r\nHost: x\r\nAuth: secret\r\nContent-Length: 3\r\n\r\n".to_slice
    expected_body = Bytes[0x41, 0x0A, 0x42]
    result[0, expected_head.size].should eq(expected_head)
    result[expected_head.size, expected_body.size].should eq(expected_body)
  ensure
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.env_prefix = "$"
  end

  it "expand_wire normalizes the whole buffer when there is no blank-line separator (all-head, no body)" do
    Gori::Settings.env_prefix = "$"
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    Gori::Env.expand_wire("GET / HTTP/1.1\nHost: x").should eq("GET / HTTP/1.1\r\nHost: x".to_slice)
  ensure
    Gori::Settings.env_prefix = "$"
  end

  it "mask_secrets passes invalid UTF-8 bytes through unchanged when nothing matches" do
    vars = {"TOKEN" => "s3cr3tXY"}
    bad = Bytes[0x41, 0x80, 0x42, 0xE2, 0x28, 0x43]
    Gori::Env.mask_secrets(String.new(bad), vars, "$").to_slice.should eq(bad)
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

  # Persistence path used by `gori run project env set|delete` (and the Project tab).
  it "save_project / load_project round-trips and upserts by key" do
    path = File.tempname("gori-env", ".db")
    store = Gori::Store.open(path)
    begin
      Gori::Settings.project_env_vars = [] of {String, String}
      Gori::Env.save_project(store, [{"TOKEN", "secret"}, {"HOST", "api.test"}])
      Gori::Settings.project_env_vars = [] of {String, String}
      Gori::Env.load_project(store)
      Gori::Settings.project_env_vars.should eq([{"TOKEN", "secret"}, {"HOST", "api.test"}])

      # Upsert TOKEN (CLI set) and drop HOST (CLI delete)
      vars = Gori::Settings.project_env_vars.dup
      if idx = vars.index { |(k, _)| k == "TOKEN" }
        vars[idx] = {"TOKEN", "new"}
      end
      vars.reject! { |(k, _)| k == "HOST" }
      Gori::Env.save_project(store, vars)
      Gori::Settings.project_env_vars = [] of {String, String}
      Gori::Env.load_project(store)
      Gori::Settings.project_env_vars.should eq([{"TOKEN", "new"}])
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      Gori::Settings.project_env_vars = [] of {String, String}
    end
  end
end
