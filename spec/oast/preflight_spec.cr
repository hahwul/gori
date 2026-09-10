require "../spec_helper"

private alias O = Gori::Oast
private alias Kind = Gori::Proxy::Upstream::DialErrorKind

# An Http seam that records what it was asked for and then answers, or raises, on script.
private class ScriptedHttp < O::Http
  getter urls = [] of String

  def initialize(@answer : O::Http::Response | Exception)
  end

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    @urls << url
    case a = @answer
    in O::Http::Response then a
    in Exception         then raise a
    end
  end
end

private def preset(host : String, kind = O::ProviderKind::Interactsh) : O::Presets::Preset
  O::Presets::Preset.new(kind, "fixture", host)
end

describe Gori::Oast::Preflight do
  describe ".probe_url" do
    it "probes the ORIGIN, not the preset's endpoint" do
      # BOAST's preset carries a path; hitting `/events` unauthenticated would make a 401 into
      # something the report has to interpret, when the question is only "can this machine
      # complete an HTTPS exchange with that host".
      O::Preflight.probe_url(preset("https://odiss.eu:2096/events", O::ProviderKind::Boast))
        .should eq("https://odiss.eu:2096/")
      O::Preflight.probe_url(preset("https://oast.pro")).should eq("https://oast.pro/")
    end

    it "keeps an unparseable host verbatim rather than inventing one" do
      O::Preflight.probe_url(preset("not a url")).should eq("not a url")
    end
  end

  describe ".check" do
    it "counts any HTTP status as reachable and records it" do
      http = ScriptedHttp.new(O::Http::Response.new(404, ""))
      result = O::Preflight.check(preset("https://oast.pro"), http)
      result.ok.should be_true
      result.stage.should eq("ok")
      result.detail.should eq("HTTP 404")
      http.urls.should eq(["https://oast.pro/"])
    end

    it "reports the dial STAGE the transport identified, not one verdict for all of them" do
      {
        Kind::Dns       => "dns",
        Kind::Connect   => "connect",
        Kind::Proxy     => "proxy",
        Kind::TlsVerify => "tls-verify",
        Kind::Tls       => "tls",
        Kind::Timeout   => "timeout",
      }.each do |kind, stage|
        err = Gori::HttpTransport::Error.new("broke at #{kind}", kind)
        result = O::Preflight.check(preset("https://oast.pro"), ScriptedHttp.new(err))
        result.ok.should be_false
        result.stage.should eq(stage)
        result.detail.should eq("broke at #{kind}")
      end
    end

    it "does not call an unattributable transport failure an exchange" do
      # nil kind is a malformed provider URL or a raise past the dial — the host was NEVER
      # reached, which is the opposite of what `exchange` means in this report.
      result = O::Preflight.check(preset("https://oast.pro"),
        ScriptedHttp.new(Gori::HttpTransport::Error.new("HTTP URL needs a host")))
      result.stage.should eq("dial")
      result.ok.should be_false
    end

    it "calls a failure past the dial an exchange, so a CA/resolver remedy is not implied" do
      result = O::Preflight.check(preset("https://oast.pro"),
        ScriptedHttp.new(Gori::Error.new("OAST: the GET to oast.pro failed after the connection was established: reset")))
      result.stage.should eq("exchange")
      result.ok.should be_false
    end

    it "never raises — a preflight that blew up is one more failure to classify by hand" do
      result = O::Preflight.check(preset("https://oast.pro"), ScriptedHttp.new(Exception.new))
      result.ok.should be_false
      result.detail.should eq("Exception")
    end
  end

  describe ".check_all" do
    it "answers every preset, in the order given, despite running them concurrently" do
      presets = [preset("https://a.example"), preset("https://b.example"), preset("https://c.example")]
      results = O::Preflight.check_all(presets, ScriptedHttp.new(O::Http::Response.new(200, "")))
      results.size.should eq(3)
      results.map(&.preset.host).should eq(["https://a.example", "https://b.example", "https://c.example"])
      results.all?(&.ok).should be_true
    end

    it "returns empty for no presets instead of blocking on a channel nobody feeds" do
      O::Preflight.check_all([] of O::Presets::Preset).should be_empty
    end
  end
end
