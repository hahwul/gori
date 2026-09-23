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
end
