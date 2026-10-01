require "../../spec_helper"

# `gori run send` (#1116) — the argument half. The request it builds is
# `Repeater::UrlRequest`'s (spec/repeater/url_request_spec.cr); what only this surface decides is
# how its flags combine, and every one of these refusals is one a command would otherwise have
# settled by silently dropping something the operator typed.
describe "gori run send (#1116)" do
  describe ".send_url_arg" do
    it "takes --url or one bare URL" do
      Gori::CLI::Run.send_url_arg("https://a.test/x", [] of String).should eq("https://a.test/x")
      Gori::CLI::Run.send_url_arg(nil, ["https://a.test/x"]).should eq("https://a.test/x")
    end

    it "refuses two answers to where, and none" do
      Gori::CLI::Run.send_url_arg("https://a.test", ["https://b.test"]).should be_a(Gori::CLI::Run::SendArgError)
      Gori::CLI::Run.send_url_arg(nil, ["https://a.test", "https://b.test"]).should be_a(Gori::CLI::Run::SendArgError)
      Gori::CLI::Run.send_url_arg(nil, [] of String).should be_a(Gori::CLI::Run::SendArgError)
      Gori::CLI::Run.send_url_arg("", [] of String).should be_a(Gori::CLI::Run::SendArgError)
    end
  end

  describe ".send_source_error" do
    it "lets a built request or one raw source through" do
      Gori::CLI::Run.send_source_error([] of String, method: "POST", headers: ["A: b"], body: "x", body_file: nil).should be_nil
      Gori::CLI::Run.send_source_error(["--request-file"], method: nil, headers: [] of String, body: nil, body_file: nil).should be_nil
    end

    # A raw request IS the method, headers and body; a -H beside it could only be dropped or
    # spliced into bytes the operator said to send as written.
    it "refuses a raw source beside a flag that builds a request, naming both" do
      err = Gori::CLI::Run.send_source_error(["--request-raw"], method: "PUT", headers: ["A: b"], body: nil, body_file: nil)
      err.not_nil!.should contain("--request-raw")
      err.not_nil!.should contain("-X/--method")
      err.not_nil!.should contain("-H/--header")
    end

    it "refuses two raw sources, and two bodies" do
      Gori::CLI::Run.send_source_error(["--request-file", "--request-stdin"], method: nil,
        headers: [] of String, body: nil, body_file: nil).not_nil!.should contain("cannot be combined")
      Gori::CLI::Run.send_source_error([] of String, method: nil, headers: [] of String,
        body: "a", body_file: "f").not_nil!.should contain("--body-file")
    end
  end

  describe ".send_header_pairs" do
    it "splits at the first colon and drops only the value's leading whitespace" do
      pairs = Gori::CLI::Run.send_header_pairs(["Accept: application/json", "X-T:\tv: w ", "Empty:"])
      pairs.should eq([{"Accept", "application/json"}, {"X-T", "v: w "}, {"Empty", ""}])
    end

    it "refuses a line that is not Name: value" do
      Gori::CLI::Run.send_header_pairs(["no colon"]).should be_a(Gori::CLI::Run::SendArgError)
      Gori::CLI::Run.send_header_pairs([": no name"]).should be_a(Gori::CLI::Run::SendArgError)
    end
  end

  # #1383: `-b` is curl's cookie and `-d` curl's body. A value with no `=` is a cookie-jar FILE
  # to curl — and what an old `-b '{"a":1}'` body looks like — so it is refused, not sent.
  describe ".cookie_header_value" do
    it "joins every -b into one Cookie value with curl's own `;`" do
      Gori::CLI::Run.cookie_header_value(["a=1", "b=2"], [] of String).should eq("a=1;b=2")
      Gori::CLI::Run.cookie_header_value([] of String, ["Cookie: x=1"]).should be_nil
    end

    it "refuses a cookie-jar file name, pointing a body at -d" do
      err = Gori::CLI::Run.cookie_header_value(["{\"a\":1}"], [] of String)
      err.should be_a(Gori::CLI::Run::SendArgError)
      err.as(Gori::CLI::Run::SendArgError).message.should contain("-d/--data")
    end

    it "refuses -b beside an explicit -H Cookie, in any case" do
      err = Gori::CLI::Run.cookie_header_value(["a=1"], ["cookie : z=1"])
      err.as(Gori::CLI::Run::SendArgError).message.should contain("both set the Cookie header")
    end
  end

  describe ".send_curl_defaults" do
    it "makes a body a form POST unless -X or -H said otherwise, as curl does" do
      m, h = Gori::CLI::Run.send_curl_defaults(nil, [{"A", "b"}], true)
      m.should eq("POST")
      h.should eq([{"A", "b"}, {"Content-Type", "application/x-www-form-urlencoded"}])
      m, h = Gori::CLI::Run.send_curl_defaults("PUT", [{"content-type", "application/json"}], true)
      m.should eq("PUT")
      h.should eq([{"content-type", "application/json"}])
    end

    it "leaves a bodyless request alone" do
      Gori::CLI::Run.send_curl_defaults(nil, [] of {String, String}, false).should eq({nil, [] of {String, String}})
    end
  end

  it "names -b among the flags a raw request source would ignore" do
    Gori::CLI::Run.send_source_error(["--request-raw"], method: nil, headers: [] of String, body: nil,
      body_file: nil, cookies: ["a=1"]).not_nil!.should contain("-b/--cookie")
  end

  # The review's case: an old `-b 'user=admin&pw=x'` body has an `=`, so the jar refusal lets it
  # through as a Cookie — it is said instead.
  describe ".cookie_as_body_note" do
    it "speaks up for a form-shaped value, or a body method with no body" do
      Gori::CLI::Run.cookie_as_body_note(["user=admin&pw=x"], nil, false).not_nil!.should contain("-d/--data")
      Gori::CLI::Run.cookie_as_body_note(["sid=1"], "post", false).should_not be_nil
    end

    it "stays quiet for an ordinary cookie, or when a body is given" do
      Gori::CLI::Run.cookie_as_body_note(["sid=1"], nil, false).should be_nil
      Gori::CLI::Run.cookie_as_body_note(["sid=1"], "POST", true).should be_nil
      Gori::CLI::Run.cookie_as_body_note([] of String, "POST", false).should be_nil
    end
  end
end

describe "gori run send -d @FILE" do
  it "says a -d naming an existing file is sent as text, and says nothing otherwise" do
    path = File.tempname("gori-send-body", ".txt")
    File.write(path, "a=1")
    begin
      note = Gori::CLI::Run.data_at_file_note(["@#{path}"]).not_nil!
      note.should contain("--body-file #{path}")
      Gori::CLI::Run.data_at_file_note(["@no-such-file-here"]).should be_nil
      Gori::CLI::Run.data_at_file_note(["a=1", "@"]).should be_nil
    ensure
      File.delete(path)
    end
  end
end
