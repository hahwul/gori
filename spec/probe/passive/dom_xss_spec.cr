require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr's private with_store/capture_flow/analyze) ---

private def with_store(&)
  path = File.tempname("gori-domxss", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Insert a flow + response and return its full FlowDetail (what the analyzer feeds Passive).
private def capture_flow(store, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n", *,
                         scheme = "https", host = "acme.test", target = "/", status = 200,
                         content_type : String? = "text/html", body : String? = nil,
                         method = "GET", req_headers = "", req_body : String? = nil) : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: req_body.try(&.to_slice))
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Run passive analysis on one flow and return ONLY the dom_xss detections.
private def dom(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select { |d| d.code == "dom_xss" }
end

# HTML page carrying an inline <script> body.
private def html_script(js : String) : String
  "<!doctype html><html><body><script>#{js}</script></body></html>"
end

describe Gori::Probe::Passive::DomXss do
  describe "#info" do
    it "declares the dom_xss rule under the client category" do
      info = Gori::Probe::Passive::DomXss.new.info
      info.id.should eq("dom_xss")
      info.category.should eq(Gori::Probe::Category::CLIENT)
    end
  end

  # (1) source flows into an HTML sink in ONE statement.
  describe "same-statement source → sink" do
    it "flags location.hash flowing into innerHTML (inline HTML script)" do
      with_store do |store|
        dets = dom(store, body: html_script("el.innerHTML = location.hash"))
        dets.size.should eq(1)
        d = dets.first
        d.code.should eq("dom_xss")
        d.category.should eq(Gori::Probe::Category::CLIENT)
        d.severity.should eq(Gori::Store::Severity::Medium)
        d.evidence.should eq("location.hash → innerHTML")
        d.title.should eq("Possible DOM-based XSS (innerHTML sink)")
        d.host.should eq("acme.test")
      end
    end

    # (2) application/javascript body: document.write(location.search).
    it "flags document.write(location.search) in a JavaScript response body" do
      with_store do |store|
        dets = dom(store, content_type: "application/javascript",
          body: "document.write(location.search)")
        dets.size.should eq(1)
        dets.first.evidence.should eq("location.search → document.write")
        dets.first.severity.should eq(Gori::Store::Severity::Medium)
      end
    end

    it "also accepts a text/ecmascript content-type as executable JS" do
      with_store do |store|
        dets = dom(store, content_type: "text/ecmascript",
          body: "eval(location.hash)")
        dets.size.should eq(1)
        dets.first.evidence.should eq("location.hash → eval")
      end
    end

    it "correlates a source that appears BEFORE the sink in the same statement" do
      with_store do |store|
        dets = dom(store, body: html_script("document.getElementById(location.hash).innerHTML = out"))
        dets.size.should eq(1)
        dets.first.evidence.should eq("location.hash → innerHTML")
      end
    end

    it "treats outerHTML and the += form as the innerHTML sink" do
      with_store do |store|
        dom(store, body: html_script("el.outerHTML = location.hash"))
          .map(&.evidence).should eq(["location.hash → innerHTML"])
        dom(store, body: html_script("el.innerHTML += location.hash"))
          .map(&.evidence).should eq(["location.hash → innerHTML"])
      end
    end
  end

  # (3) dedup: one detection per distinct source→sink SHAPE per host.
  describe "per-host dedup by source→sink shape" do
    it "collapses two identical innerHTML=location.hash into one detection" do
      with_store do |store|
        body = "<html><body>" \
               "<script>a.innerHTML = location.hash</script>" \
               "<script>b.innerHTML = location.hash</script>" \
               "</body></html>"
        dets = dom(store, body: body)
        dets.size.should eq(1)
        dets.first.evidence.should eq("location.hash → innerHTML")
      end
    end

    it "keeps DISTINCT shapes as separate detections" do
      with_store do |store|
        body = "<html><body>" \
               "<script>el.innerHTML = location.hash</script>" \
               "<script>document.write(location.search)</script>" \
               "</body></html>"
        dets = dom(store, body: body)
        dets.compact_map(&.evidence).sort!.should eq([
          "location.hash → innerHTML",
          "location.search → document.write",
        ])
      end
    end
  end

  # (4) a bare sink with no source does NOT flag.
  describe "bare sink (no source)" do
    it "does not flag el.innerHTML = sanitize(x)" do
      with_store do |store|
        dom(store, body: html_script("el.innerHTML = sanitize(userInput)")).should be_empty
      end
    end

    it "does not flag document.write of a static string" do
      with_store do |store|
        dom(store, content_type: "application/javascript",
          body: "document.write(\"<b>static</b>\")").should be_empty
      end
    end

    it "does not flag an innerHTML == comparison (negative lookahead on '=')" do
      with_store do |store|
        # `innerHTML ==` is a read/compare, not an assignment sink: the (?!=) guard rejects it.
        dom(store, body: html_script("if (el.innerHTML == location.hash) { warn() }")).should be_empty
      end
    end
  end

  # (5) source/sink only inside a string or comment does NOT flag (client_code is stripped).
  describe "string/comment noise is stripped" do
    it "does not flag a source→sink that lives in a // line comment" do
      with_store do |store|
        dom(store, body: html_script("// el.innerHTML = location.hash")).should be_empty
      end
    end

    it "does not flag a source→sink that lives in a /* block */ comment" do
      with_store do |store|
        dom(store, body: html_script("/* el.innerHTML = location.hash */")).should be_empty
      end
    end

    it "does not flag a source→sink that lives entirely inside a string literal" do
      with_store do |store|
        dom(store, body: html_script("var doc = \"el.innerHTML = location.hash\"")).should be_empty
      end
    end
  end

  # (6) template-literal sink: interpolation keeps the source as code.
  describe "template-literal sink" do
    it "flags innerHTML = `${location.hash}` (interpolated source survives strip)" do
      with_store do |store|
        dets = dom(store, body: html_script("el.innerHTML = `<p>${location.hash}</p>`"))
        dets.size.should eq(1)
        dets.first.evidence.should eq("location.hash → innerHTML")
      end
    end

    it "still flags an UNTERMINATED template literal without raising" do
      with_store do |store|
        # Truncated backtick string: the strip pass must not crash, and the interpolated
        # source is still recovered as code.
        dets = dom(store, content_type: "application/javascript",
          body: "el.innerHTML = `x${location.hash}")
        dets.map(&.evidence).should eq(["location.hash → innerHTML"])
      end
    end
  end

  # (7) every sink-kind evidence label resolves.
  describe "sink-kind labels" do
    cases = [
      {"el.insertAdjacentHTML('beforeend', location.hash)", "location.hash → insertAdjacentHTML"},
      {"document.writeln(location.search)", "location.search → document.write"},
      {"eval(location.hash)", "location.hash → eval"},
      {"new Function(location.hash)", "location.hash → Function"},
      {"setTimeout(location.hash, 10)", "location.hash → setTimeout/setInterval"},
      {"setInterval(location.hash, 10)", "location.hash → setTimeout/setInterval"},
      {"el.dangerouslySetInnerHTML = location.hash", "location.hash → dangerouslySetInnerHTML"},
      {"$('#out').html(location.hash)", "location.hash → jQuery.html()"},
      {"frame.srcdoc = location.hash", "location.hash → iframe.srcdoc"},
    ]

    cases.each do |(code, evidence)|
      it "labels #{evidence}" do
        with_store do |store|
          dets = dom(store, content_type: "application/javascript", body: code)
          dets.size.should eq(1)
          dets.first.evidence.should eq(evidence)
          dets.first.severity.should eq(Gori::Store::Severity::Medium)
        end
      end
    end
  end

  # A range of taint sources all resolve to their fixed labels.
  describe "source labels" do
    sources = {
      "location.href"             => "location.href",
      "location.pathname"         => "location.href",
      "document.URL"              => "document.URL",
      "document.referrer"         => "document.referrer",
      "document.cookie"           => "document.cookie",
      "window.name"               => "window.name",
      "history.state"             => "history.state",
      "event.data"                => "postMessage data",
      "localStorage.getItem('k')" => "web storage",
    }

    sources.each do |expr, label|
      it "labels #{expr} as #{label}" do
        with_store do |store|
          dets = dom(store, content_type: "application/javascript", body: "el.innerHTML = #{expr}")
          dets.size.should eq(1)
          dets.first.evidence.should eq("#{label} → innerHTML")
        end
      end
    end
  end

  # (8) early gate: empty scripts / non-HTML-non-JS content-type → no detection.
  describe "gating" do
    it "does not flag when the content-type is text/plain" do
      with_store do |store|
        dom(store, content_type: "text/plain", body: "el.innerHTML = location.hash").should be_empty
      end
    end

    it "does not flag when there is no content-type" do
      with_store do |store|
        dom(store, content_type: nil, body: "el.innerHTML = location.hash").should be_empty
      end
    end

    it "does not flag an empty body" do
      with_store do |store|
        dom(store, body: nil).should be_empty
        dom(store, body: "").should be_empty
      end
    end

    it "does not flag an empty <script></script> block" do
      with_store do |store|
        dom(store, body: "<html><body><script></script></body></html>").should be_empty
      end
    end

    it "skips an EXTERNAL <script src=...> even if it has decorative inline text" do
      with_store do |store|
        body = "<script src=\"/app.js\">el.innerHTML = location.hash</script>"
        dom(store, body: body).should be_empty
      end
    end

    it "skips a non-JS <script type> data/template island" do
      with_store do |store|
        body = "<script type=\"application/json\">{\"x\":\"el.innerHTML = location.hash\"}</script>"
        dom(store, body: body).should be_empty
      end
    end
  end

  # Heuristic limits stated in the doc comment: same-statement only.
  describe "documented heuristic limits" do
    it "does NOT follow a source through an intermediate variable (separate statements)" do
      with_store do |store|
        # `;` ends the statement; the sink's statement holds only `x`, no taint source.
        dom(store, body: html_script("var x = location.hash; el.innerHTML = x;")).should be_empty
      end
    end

    it "does NOT correlate a source separated from the sink by a statement boundary" do
      with_store do |store|
        # Newline-separated statements: source is not in the sink's statement window.
        dom(store, content_type: "application/javascript",
          body: "var t = location.hash\nel.innerHTML = safe").should be_empty
      end
    end
  end

  # Window boundary: WINDOW = 250 chars each side (measured on the stripped code).
  describe "statement window boundary" do
    it "flags a source within the window on the same long statement" do
      with_store do |store|
        filler = "a" * 100
        dom(store, content_type: "application/javascript",
          body: "el.innerHTML = concat(#{filler} + location.hash)")
          .map(&.evidence).should eq(["location.hash → innerHTML"])
      end
    end

    it "does NOT flag a source pushed beyond the 250-char window" do
      with_store do |store|
        filler = "a" * 300 # > WINDOW; no ; { } newline and no source substring inside
        dom(store, content_type: "application/javascript",
          body: "el.innerHTML = concat(#{filler} + location.hash)").should be_empty
      end
    end
  end

  # Unicode / multibyte forces the Array(Char) strip path (offset-preserving).
  describe "unicode / multibyte inputs" do
    it "flags with CJK + emoji in a trailing comment (non-ASCII strip path)" do
      with_store do |store|
        dets = dom(store, body: html_script("el.innerHTML = location.hash; // 안녕 世界 🎉"))
        dets.map(&.evidence).should eq(["location.hash → innerHTML"])
      end
    end

    it "does NOT flag when the whole source→sink sits inside a CJK comment" do
      with_store do |store|
        dom(store, body: html_script("// 안녕 el.innerHTML = location.hash 世界")).should be_empty
      end
    end

    it "flags across a multibyte block comment separating source and sink code" do
      with_store do |store|
        dets = dom(store, content_type: "application/javascript",
          body: "el.innerHTML = /* 세계 コメント */ location.hash")
        dets.map(&.evidence).should eq(["location.hash → innerHTML"])
      end
    end
  end

  # Adversarial / malformed input must be handled safely.
  describe "adversarial input" do
    it "scrubs invalid UTF-8 bytes and still flags the clean script" do
      with_store do |store|
        body = String.new(html_script("el.innerHTML = location.hash").to_slice + Bytes[0xff, 0xfe, 0x80])
        dets = dom(store, body: body)
        dets.map(&.evidence).should eq(["location.hash → innerHTML"])
      end
    end

    it "completes quickly on a large repetitive body and dedups to one detection" do
      with_store do |store|
        huge = "el.innerHTML = location.hash;\n" * 5_000
        dets = [] of Gori::Probe::Detection
        elapsed = Time.measure { dets = dom(store, content_type: "application/javascript", body: huge) }
        dets.size.should eq(1)
        dets.first.evidence.should eq("location.hash → innerHTML")
        elapsed.should be < 5.seconds
      end
    end

    it "does not hang on a long backtracking-bait body with no source" do
      with_store do |store|
        bait = ".innerHTML=" + ("a" * 50_000)
        elapsed = Time.measure do
          dom(store, content_type: "application/javascript", body: bait).should be_empty
        end
        elapsed.should be < 5.seconds
      end
    end
  end
end
