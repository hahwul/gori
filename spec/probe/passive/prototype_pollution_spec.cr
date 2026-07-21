require "../../spec_helper"

# --- file-local harness (mirrors spec/probe_spec.cr) -----------------------------------
private def with_store(&)
  path = File.tempname("gori-protopoll", ".db")
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
private def capture_flow(store, resp_head : String, *, scheme = "https", host = "acme.test",
                         target = "/", status = 200, content_type : String? = "text/html",
                         body : String? = nil, method = "GET", req_headers = "",
                         req_body : String? = nil) : Gori::Store::FlowDetail
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

# Run passive analysis on one flow and return the detections (ungrouped).
private def analyze(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw))
end

private def codes_of(dets : Array(Gori::Probe::Detection)) : Array(String)
  dets.map(&.code)
end

# Build a FlowDetail directly (no store) so a request head / body can carry RAW,
# possibly non-UTF-8 bytes — the byte-safety path the store round-trip would obscure.
# Only `request_head` (and optionally `request_body`) carry the adversarial bytes; the
# row target stays clean ASCII (req.target is parsed from the head, not the row).
private def raw_detail(req_head : Bytes, *, req_body : Bytes? = nil,
                       content_type : String? = nil) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", "GET", "acme.test", 443, "/", 200,
    0_i64, Gori::Store::FlowState::Complete, nil, nil, content_type)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", req_head, req_body, nil, nil)
end

# A JS response body wrapped so the whole body is treated as one client script.
private def js_dets(store, code : String) : Array(Gori::Probe::Detection)
  analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
    content_type: "application/javascript", body: code)
end

private def proto_sink_count(dets : Array(Gori::Probe::Detection)) : Int32
  dets.count(&.code.==("prototype_pollution"))
end

describe Gori::Probe::Passive::PrototypePollution do
  # ---------------------------------------------------------------------------------------
  # CLIENT SINK path (scans Context#client_scripts_nocomment): one Low per SINK_PATTERNS label
  # ---------------------------------------------------------------------------------------
  describe "client-script sinks" do
    it "flags obj.__proto__ = ... as a Low '__proto__ assignment'" do
      with_store do |store|
        dets = js_dets(store, "obj.__proto__ = payload;")
        proto_sink_count(dets).should eq(1)
        hit = dets.find(&.code.==("prototype_pollution")).not_nil!
        hit.severity.should eq(Gori::Store::Severity::Low)
        hit.evidence.should eq("__proto__ assignment")
        hit.category.should eq("client")
      end
    end

    it %(flags x["__proto__"] = ... as a Low '__proto__ key assignment') do
      with_store do |store|
        dets = js_dets(store, %(x["__proto__"] = payload;))
        proto_sink_count(dets).should eq(1)
        dets.find(&.code.==("prototype_pollution")).not_nil!.evidence
          .should eq("__proto__ key assignment")
      end
    end

    it "matches single- and back-quoted __proto__ key forms too" do
      with_store do |store|
        js_dets(store, %(x['__proto__'] = v;)).find(&.code.==("prototype_pollution"))
          .not_nil!.evidence.should eq("__proto__ key assignment")
        js_dets(store, %(x[`__proto__`] = v;)).find(&.code.==("prototype_pollution"))
          .not_nil!.evidence.should eq("__proto__ key assignment")
      end
    end

    it "flags constructor.prototype[k] as a Low 'constructor.prototype[] write'" do
      with_store do |store|
        dets = js_dets(store, "foo.constructor.prototype[k] = 1;")
        proto_sink_count(dets).should eq(1)
        dets.find(&.code.==("prototype_pollution")).not_nil!.evidence
          .should eq("constructor.prototype[] write")
      end
    end

    it "flags Object.prototype[k] as a Low 'Object.prototype[] write'" do
      with_store do |store|
        dets = js_dets(store, "Object.prototype[key] = value;")
        proto_sink_count(dets).should eq(1)
        dets.find(&.code.==("prototype_pollution")).not_nil!.evidence
          .should eq("Object.prototype[] write")
      end
    end

    it "flags $.extend(true, a, b) as a Low '$.extend(true) deep merge'" do
      with_store do |store|
        dets = js_dets(store, "$.extend(true, target, source);")
        proto_sink_count(dets).should eq(1)
        dets.find(&.code.==("prototype_pollution")).not_nil!.evidence
          .should eq("$.extend(true) deep merge")
      end
    end

    it "does NOT flag a shallow $.extend(a, b) (no leading true)" do
      with_store do |store|
        proto_sink_count(js_dets(store, "$.extend(target, source);")).should eq(0)
      end
    end

    it "flags lodash _.merge(a, b) as a Low 'lodash deep merge/set'" do
      with_store do |store|
        dets = js_dets(store, "_.merge(dst, src);")
        proto_sink_count(dets).should eq(1)
        dets.find(&.code.==("prototype_pollution")).not_nil!.evidence
          .should eq("lodash deep merge/set")
      end
    end

    it "matches the other lodash pollution-prone APIs (mergeWith/defaultsDeep/set/setWith)" do
      with_store do |store|
        %w[mergeWith defaultsDeep set setWith].each do |fn|
          js_dets(store, "_.#{fn}(a, b);").find(&.code.==("prototype_pollution"))
            .not_nil!.evidence.should eq("lodash deep merge/set")
        end
      end
    end

    it "emits ONE detection per label when every shape appears in one script" do
      with_store do |store|
        body = <<-JS
          obj.__proto__ = a;
          x["__proto__"] = b;
          foo.constructor.prototype[k] = 1;
          Object.prototype[k] = 2;
          $.extend(true, t, s);
          _.merge(d, e);
          JS
        dets = js_dets(store, body)
        proto_sink_count(dets).should eq(6)
        labels = dets.select(&.code.==("prototype_pollution")).map(&.evidence)
        labels.should contain("__proto__ assignment")
        labels.should contain("__proto__ key assignment")
        labels.should contain("constructor.prototype[] write")
        labels.should contain("Object.prototype[] write")
        labels.should contain("$.extend(true) deep merge")
        labels.should contain("lodash deep merge/set")
        labels.uniq.size.should eq(6) # no duplicate label (dedup on the seen-set)
      end
    end

    it "de-dups a label seen across multiple inline scripts (HTML with two <script>s)" do
      with_store do |store|
        html = "<html><script>obj.__proto__ = a;</script>" \
               "<script>other.__proto__ = b;</script></html>"
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          content_type: "text/html", body: html)
        proto_sink_count(dets).should eq(1) # same label collapses to one
      end
    end

    it "keeps the string-key form visible (it is NOT stripped like a comment)" do
      with_store do |store|
        # strip_comments blanks comments but KEEPS string-literal contents, so a "__proto__"
        # written as a bracket-string key still matches.
        proto_sink_count(js_dets(store, %(payload["__proto__"] = 1;))).should eq(1)
      end
    end

    it "matches a sink on a non-ASCII (CJK) receiver identifier" do
      with_store do |store|
        proto_sink_count(js_dets(store, "안녕.__proto__ = 世界;")).should eq(1)
      end
    end

    # -- comment / negative-lookahead false-positive guards --------------------------------
    it "does NOT flag a __proto__ assignment that lives inside a // line comment" do
      with_store do |store|
        proto_sink_count(js_dets(store, "// obj.__proto__ = evil;\nvar ok = 1;")).should eq(0)
      end
    end

    it "does NOT flag a __proto__ assignment inside a /* block */ comment" do
      with_store do |store|
        proto_sink_count(js_dets(store, "/* Object.prototype[x] = 1; $.extend(true,a,b) */")).should eq(0)
      end
    end

    it "does NOT match a comparison (negative lookahead on '='): obj.__proto__ == poison" do
      with_store do |store|
        # The `==` is exactly what `=(?!=)` rejects — a comparison is not an assignment.
        proto_sink_count(js_dets(store, "if (obj.__proto__ == poison) alert(1);")).should eq(0)
      end
    end

    it "does NOT match the literal 'x == obj.__proto__' read (no '=' follows __proto__)" do
      with_store do |store|
        proto_sink_count(js_dets(store, "var y = x == obj.__proto__;")).should eq(0)
      end
    end

    it "does NOT match a strict-equality bracket read x[\"__proto__\"] === y" do
      with_store do |store|
        code = %(if (x["__proto__"] === y) { z(); })
        proto_sink_count(js_dets(store, code)).should eq(0)
      end
    end

    it "produces no sink detection for an empty or sink-free script" do
      with_store do |store|
        proto_sink_count(js_dets(store, "")).should eq(0)
        proto_sink_count(js_dets(store, "const a = 1; function f(){ return a + 2; }")).should eq(0)
      end
    end

    it "does not run the client path for a non-document (no HTML/JS content-type)" do
      with_store do |store|
        # content_type nil → client_scripts empty → sink path never engages.
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          content_type: nil, body: "obj.__proto__ = evil;")
        proto_sink_count(dets).should eq(0)
      end
    end
  end

  # ---------------------------------------------------------------------------------------
  # REQUEST path (pure string work): prototype_pollution_param, Low
  # ---------------------------------------------------------------------------------------
  describe "request parameter surface" do
    it "flags a __proto__ key in the request TARGET (Low)" do
      with_store do |store|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          target: "/api?__proto__[x]=1", content_type: nil)
        hit = dets.find(&.code.==("prototype_pollution_param")).not_nil!
        hit.severity.should eq(Gori::Store::Severity::Low)
        hit.evidence.should eq("__proto__/constructor.prototype in request")
        hit.category.should eq("client")
      end
    end

    it "flags a constructor[prototype] target: requires BOTH substrings present" do
      with_store do |store|
        both = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          target: "/api?constructor[prototype][x]=1", content_type: nil)
        codes_of(both).should contain("prototype_pollution_param")

        # Both substrings anywhere in the target qualify (independent includes?, not adjacency).
        split = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          target: "/api?constructor=1&role=prototype", content_type: nil)
        codes_of(split).should contain("prototype_pollution_param")
      end
    end

    it "does NOT flag a target carrying only ONE of constructor / prototype" do
      with_store do |store|
        only_c = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          target: "/api?constructor[x]=1", content_type: nil)
        codes_of(only_c).should_not contain("prototype_pollution_param")
        only_p = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          target: "/api?prototype[x]=1", content_type: nil)
        codes_of(only_p).should_not contain("prototype_pollution_param")
      end
    end

    it "does NOT flag a benign target with no prototype key" do
      with_store do |store|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n",
          target: "/api?user=alice&page=2", content_type: nil)
        codes_of(dets).should_not contain("prototype_pollution_param")
      end
    end

    it "flags a __proto__ key in a urlencoded request BODY (REQ_BODY_PROTO)" do
      with_store do |store|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_headers: "Content-Type: application/x-www-form-urlencoded\r\n",
          req_body: "a[__proto__][b]=1&x=2")
        codes_of(dets).should contain("prototype_pollution_param")
      end
    end

    it "flags a __proto__ key in a JSON request BODY" do
      with_store do |store|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_headers: "Content-Type: application/json\r\n",
          req_body: %({"__proto__":{"polluted":true}}))
        codes_of(dets).should contain("prototype_pollution_param")
      end
    end

    it "flags URL-encoded constructor%5Bprototype%5D in the body (case-insensitive, %5B/[ alt)" do
      with_store do |store|
        upper = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_body: "constructor%5Bprototype%5D%5Bx%5D=1")
        codes_of(upper).should contain("prototype_pollution_param")

        # lowercase %5b + mixed case constructor/prototype — the /i flag covers it.
        lower = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_body: "CONSTRUCTOR%5bPROTOTYPE%5d=1")
        codes_of(lower).should contain("prototype_pollution_param")

        # the open-bracket alternation also matches a raw '[' form in the body.
        bracket = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_body: "constructor[prototype][x]=1")
        codes_of(bracket).should contain("prototype_pollution_param")
      end
    end

    it "honours the bounded proximity cap between constructor%5B and prototype (12 chars)" do
      with_store do |store|
        # `constructor(?:\[|%5B).{0,12}prototype` — exactly 12 filler chars still matches...
        gap12 = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_body: "constructor%5B" + ("a" * 12) + "prototype=1")
        codes_of(gap12).should contain("prototype_pollution_param")
        # ...but a 13-char gap exceeds the cap and does not match this alternation.
        gap13 = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_body: "constructor%5B" + ("a" * 13) + "prototype=1")
        codes_of(gap13).should_not contain("prototype_pollution_param")
      end
    end

    it "does NOT flag a benign request body without a prototype key" do
      with_store do |store|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/submit", content_type: nil,
          req_body: %({"name":"alice","role":"admin"}))
        codes_of(dets).should_not contain("prototype_pollution_param")
      end
    end

    it "emits at most one request-parameter detection even when target AND body both carry it" do
      with_store do |store|
        dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
          target: "/api?__proto__[x]=1", content_type: nil,
          req_body: %({"__proto__":{}}))
        dets.count(&.code.==("prototype_pollution_param")).should eq(1)
      end
    end
  end

  # ---------------------------------------------------------------------------------------
  # BYTE-SAFETY (item 8): non-UTF-8 target uses includes? (no PCRE); body is scrubbed then regex
  # ---------------------------------------------------------------------------------------
  describe "byte-safety on adversarial input" do
    it "scans a non-UTF-8 request TARGET with includes? without raising (and still detects)" do
      with_store do |_|
        head = IO::Memory.new
        head << "GET /api?"
        head.write(Bytes[0xff, 0xfe, 0x80]) # invalid UTF-8, kept away from the token
        head << "&__proto__[x]=1 HTTP/1.1\r\nHost: h\r\n\r\n"
        dets = Gori::Probe::Passive.analyze(raw_detail(head.to_slice))
        codes_of(dets).should contain("prototype_pollution_param")
      end
    end

    it "does not raise or flag on a non-UTF-8 target that carries no prototype key" do
      with_store do |_|
        head = IO::Memory.new
        head << "GET /api?q="
        head.write(Bytes[0xc0, 0xc1, 0xff]) # invalid UTF-8, no proto substring
        head << " HTTP/1.1\r\nHost: h\r\n\r\n"
        dets = Gori::Probe::Passive.analyze(raw_detail(head.to_slice))
        codes_of(dets).should_not contain("prototype_pollution_param")
      end
    end

    it "regex-scans a request BODY holding invalid UTF-8 safely (scrubbed first, then matched)" do
      with_store do |_|
        req_head = "POST /submit HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        # invalid bytes precede the token but stay separated so the scrub cannot break adjacency.
        body = IO::Memory.new
        body << "junk="
        body.write(Bytes[0xff, 0xfe])
        body << "&a[__proto__][b]=1"
        dets = Gori::Probe::Passive.analyze(raw_detail(req_head, req_body: body.to_slice))
        codes_of(dets).should contain("prototype_pollution_param")
      end
    end

    it "completes quickly on a large adversarial 'constructor' body with no bracket (no ReDoS)" do
      with_store do |store|
        # `constructor(?:\[|%5B)…` never engages without a following bracket; the other
        # alternations are anchor-free but linear. A big repeat must finish fast and not match.
        blob = "constructor" * 20_000
        elapsed = Time.measure do
          dets = analyze(store, resp_head: "HTTP/1.1 200 OK\r\n\r\n", method: "POST",
            target: "/submit", content_type: nil, req_body: blob)
          codes_of(dets).should_not contain("prototype_pollution_param")
        end
        elapsed.total_seconds.should be < 2.0
      end
    end
  end
end
