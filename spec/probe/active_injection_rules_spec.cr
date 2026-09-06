require "../spec_helper"
require "../support/probe_harness"

# A backend that returns one fixed response for every probe, so an Active.analyze integration test
# can drive the full plan → send → detections dispatch without a socket.
private class FixedBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin

  def initialize(@origin : Gori::Fuzz::Origin, @head : String, @body : String = "")
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(@head.to_slice, @body.empty? ? Bytes.empty : @body.to_slice, nil, 1_i64)
  end
end

describe "Gori::Probe::Active::BackslashPowered" do
  probe = Gori::Probe::Active::BackslashPowered.new
  # A probe response with a given status + optional body (bodies drive error-signature classing).
  resp = ->(status : Int32, body : String) do
    head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "plans a GET query param into a baseline + a `\\` / `\\\\` follow-up pair" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["q"])
      plan.followups.size.should eq(3)
      String.new(plan.request).should contain("/s?q=hi ")         # baseline: value unchanged
      String.new(plan.followups[0]).should contain("/s?q=hi ")    # baseline again (stability check)
      String.new(plan.followups[1]).should contain("q=hi%5C ")    # single: value\
      String.new(plan.followups[2]).should contain("q=hi%5C%5C ") # double: value\\
    end
  end

  it "caps the probed params at MAX_PROBE_PARAMS (in query order)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&b=2&c=3&d=4")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["a", "b", "c"])
      plan.followups.size.should eq(7)                               # 2nd baseline + 2 per probed param
      String.new(plan.request).should contain("/s?a=1&b=2&c=3&d=4 ") # every param kept in the baseline
    end
  end

  it "does not plan a POST, a HEAD, or a paramless GET" do
    with_store do |store|
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "HEAD")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
    end
  end

  it "plans a POST query param under allow_unsafe, but never HEAD (no body to diff)" do
    with_store do |store|
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.plan(post, unsafe).not_nil!.params.map(&.name).should eq(["q"])
      probe.dedup_key(post, unsafe).should eq(probe.plan(post, unsafe).try(&.dedup_key))
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "HEAD"), unsafe).should be_nil
      # A paramless request still has nothing to inject even under the opt-in.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s", method: "POST"), unsafe).should be_nil
    end
  end

  it "raises the param cap under aggressive opts" do
    with_store do |store|
      wide = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?" + (0...6).map { |i| "p#{i}=v" }.join("&"))
      # Default: capped at MAX_PROBE_PARAMS (3).
      probe.plan(wide).not_nil!.params.size.should eq(Gori::Probe::Active::BackslashPowered::MAX_PROBE_PARAMS)
      # Aggressive: all 6 params probed (< MAX_PROBE_PARAMS_AGGRESSIVE).
      probe.plan(wide, Gori::Probe::Active::Options.new(aggressive: true)).not_nil!.params.size.should eq(6)
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?q=1", "/s?a=1&b=2&c=3&d=4", "/s?flag&x=9", "/s"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end

  it "flags a param whose lone `\\` breaks but doubled `\\\\` does not" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      dets = probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), resp.call(500, ""), resp.call(200, "")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("backslash_powered")
      dets.first.category.should eq(Gori::Probe::Category::ACTIVE)
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      dets.first.evidence.not_nil!.should contain("q")
    end
  end

  it "fires on an interpreter error surfaced only by the lone backslash (status unchanged)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      results = [resp.call(200, "welcome"), resp.call(200, "welcome"),
                 resp.call(200, "You have an error in your SQL syntax"), resp.call(200, "welcome")]
      dets = probe.detections_all(plan, results, detail)
      dets.size.should eq(1)
      dets.first.evidence.not_nil!.downcase.should contain("sql")
    end
  end

  it "does not fire when BOTH `\\` and `\\\\` change the response (generic rejection, not escaping)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), resp.call(500, ""), resp.call(500, "")], detail).should be_empty
    end
  end

  it "does not fire when nothing changed" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), resp.call(200, ""), resp.call(200, "")], detail).should be_empty
    end
  end

  it "skips a param whose probe leg failed to send (incomplete comparison)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(200, ""), errored, resp.call(200, "")], detail).should be_empty
    end
  end

  it "flags only the affected param when several are probed" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?a=1&b=2")
      plan = probe.plan(detail).not_nil!
      # baseline, baseline2, a\, a\\, b\, b\\  — only `a` shows the escape asymmetry
      results = [resp.call(200, ""), resp.call(200, ""),
                 resp.call(500, ""), resp.call(200, ""), resp.call(200, ""), resp.call(200, "")]
      dets = probe.detections_all(plan, results, detail)
      dets.size.should eq(1)
      ev = dets.first.evidence.not_nil!
      ev.should contain("a")
      ev.should_not contain("b")
    end
  end

  # The whole rule is a difference test against the baseline, which assumes the endpoint answers
  # the same request the same way twice. When it does not, an asymmetry carries no information.
  it "declines when the two baselines disagree (endpoint is not stable enough to diff)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # Exactly the asymmetry the rule reports — but the endpoint already contradicted itself
      # on two identical requests, so the `\` leg's 500 proves nothing.
      probe.detections_all(plan,
        [resp.call(200, ""), resp.call(503, ""), resp.call(500, ""), resp.call(200, "")], detail).should be_empty
      # An error signature that appears on only one baseline is the same problem.
      probe.detections_all(plan,
        [resp.call(200, "welcome"), resp.call(200, "You have an error in your SQL syntax"),
         resp.call(500, ""), resp.call(200, "welcome")], detail).should be_empty
    end
  end

  # The technique's central signal is a body that CHANGED, which a {status, error-class}
  # fingerprint alone could not see: same 200, no recognised error string, completely different
  # page read as "identical". Body length joins the fingerprint only when the two baselines
  # proved the endpoint reproduces its own length.
  it "fires on a body that changed shape with no status flip and no error string" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # Both baselines are byte-identical → length is trustworthy → the `\` leg's shorter body
      # is a real difference, and the `\\` leg reverting to baseline is the escape asymmetry.
      dets = probe.detections_all(plan,
        [resp.call(200, "the full rendered page"), resp.call(200, "the full rendered page"),
         resp.call(200, "oops"), resp.call(200, "the full rendered page")], detail)
      dets.size.should eq(1)
      dets.first.evidence.not_nil!.should contain("body")
    end
  end

  # …but a length-jittery endpoint must NOT get the sharper comparison, or every page with a
  # timestamp in it becomes a finding. It falls back to status + error-class, not to nothing.
  it "falls back to the status/error fingerprint when the baseline length is not reproducible" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      # Baselines differ ONLY in length → length is dropped from the fingerprint → a `\` leg that
      # differs only in length is no longer a difference.
      probe.detections_all(plan,
        [resp.call(200, "rendered at 10:00:00"), resp.call(200, "rendered at 10:00:01x"),
         resp.call(200, "short"), resp.call(200, "rendered at 10:00:02")], detail).should be_empty
      # The status flip still fires on that same jittery endpoint — the check is not lost.
      probe.detections_all(plan,
        [resp.call(200, "rendered at 10:00:00"), resp.call(200, "rendered at 10:00:01x"),
         resp.call(500, "boom"), resp.call(200, "rendered at 10:00:02")], detail).size.should eq(1)
    end
  end

  it "declines when the second baseline is missing or failed to send" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      errored = Gori::Repeater::Result.new(Bytes.empty, nil, nil, 1_i64, "connection refused")
      probe.detections_all(plan, [resp.call(200, "")], detail).should be_empty
      probe.detections_all(plan,
        [resp.call(200, ""), errored, resp.call(500, ""), resp.call(200, "")], detail).should be_empty
    end
  end
end

describe "Gori::Probe::Active::GraphqlIntrospection" do
  probe = Gori::Probe::Active::GraphqlIntrospection.new
  resp = ->(status : Int32, ct : String, body : String) do
    head = "HTTP/1.1 #{status} X\r\nContent-Type: #{ct}\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "re-POSTs a read-only introspection body when the captured flow was a GraphQL POST" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"query":"{me{id}}"}))
      plan = probe.plan(detail).not_nil!
      req = String.new(plan.request)
      req.should contain("POST /graphql ")
      req.should contain("Content-Type: application/json")
      req.should contain(%({"query":"{__schema{queryType{name}}}"}))
      req.should_not contain("{me{id}}") # NEVER replays the captured body
    end
  end

  it "strips Transfer-Encoding from a chunked source so the POST probe is well-framed" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "POST",
        req_headers: "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n", req_body: "1\r\nx\r\n0\r\n\r\n")
      req = String.new(probe.plan(detail).not_nil!.request)
      req.downcase.should_not contain("transfer-encoding")
      req.should contain("Content-Length:")
      req.should contain(%({"query":"{__schema{queryType{name}}}"}))
    end
  end

  it "sends a GET introspection query for a GET graphql endpoint" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql?x=1", method: "GET")
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain("GET /graphql?query=%7B__schema")
      req.should_not contain("x=1") # the original query is replaced, not appended
    end
  end

  it "detects introspection from the `\"__schema\":{` result envelope" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"query":"{me{id}}"}))
      plan = probe.plan(detail).not_nil!
      body = %({"data":{"__schema":{"queryType":{"name":"Query"}}}})
      dets = probe.detections(plan, resp.call(200, "application/json", body), detail)
      dets.size.should eq(1)
      dets.first.code.should eq("graphql_introspection")
      dets.first.category.should eq(Gori::Probe::Category::INFOLEAK)
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
    end
  end

  it "does not fire on a disabled-introspection error, nor on a query echo" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql?x=1", method: "GET")
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, resp.call(200, "application/json",
        %({"errors":[{"message":"introspection is disabled"}]})), detail).should be_empty
      # A response that merely echoes the query has `__schema` UNQUOTED — the anchor rejects it.
      probe.detections(plan, resp.call(200, "application/json",
        %({"data":null,"query":"{ __schema { queryType { name } } }"})), detail).should be_empty
    end
  end

  it "plans nothing for a non-GraphQL flow" do
    with_store do |store|
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/api/users")).should be_nil
      # A POST with a non-GraphQL JSON body (query is an object, not a string) is not GraphQL.
      es = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/search", method: "POST",
        req_headers: "Content-Type: application/json\r\n", req_body: %({"query":{"match_all":{}}}))
      probe.plan(es).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      [{"/graphql", "GET"}, {"/graphql?x=1", "GET"}, {"/api/graphql", "POST"}, {"/graphql", "HEAD"},
       {"http://acme.test/graphql", "GET"}, {"/users", "GET"}].each do |(t, m)|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, method: m)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      # GET and HEAD both probe with GET → the SAME dedup key (folded).
      g = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "GET")
      h = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/graphql", method: "HEAD")
      probe.dedup_key(g).should eq(probe.dedup_key(h))
    end
  end
end

describe "Gori::Probe::Active::LfiParamTraversal" do
  probe = Gori::Probe::Active::LfiParamTraversal.new
  resp = ->(status : Int32, body : String) do
    head = "HTTP/1.1 #{status} X\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, body.empty? ? Bytes.empty : body.to_slice, nil, 1_i64)
  end

  it "plans a fold + encoded-fold + control for a path-like parameter" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "X")
      plan = probe.plan(detail).not_nil!
      plan.followups.size.should eq(2)
      String.new(plan.request).should contain("file=x/../doc.pdf")
      String.new(plan.followups[0]).should contain("file=x/%2e%2e/doc.pdf")
      String.new(plan.followups[1]).should contain("file=x/zzznope/doc.pdf")
    end
  end

  it "flags High when a folded `..` returns byte-identical content and the control differs" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      dets = probe.detections_all(plan, [resp.call(200, "PDFDATA"), resp.call(200, "PDFDATA"), resp.call(404, "nope")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("lfi_param_traversal")
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.evidence.not_nil!.should contain("file")
    end
  end

  it "fires on the encoded-fold variant when the literal fold is blocked" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, [resp.call(403, "blocked"), resp.call(200, "PDFDATA"), resp.call(404, "nope")], detail)
        .size.should eq(1)
    end
  end

  it "does not fire on a catch-all where the control also matches the baseline" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, [resp.call(200, "PDFDATA"), resp.call(200, "PDFDATA"), resp.call(200, "PDFDATA")], detail)
        .should be_empty
    end
  end

  it "does not fire when the folded value returns different content" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "PDFDATA")
      plan = probe.plan(detail).not_nil!
      probe.detections_all(plan, [resp.call(200, "OTHER"), resp.call(200, "OTHER"), resp.call(404, "nope")], detail)
        .should be_empty
    end
  end

  it "gates on a path-like param, 2xx, a body, and a safe method" do
    with_store do |store|
      # Not path-like (no `/`, no extension, unknown name).
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi", body: "X")).should be_nil
      # A known file-ish name qualifies even without an extension.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=secret", body: "X")).should_not be_nil
      # Captured non-2xx / no body / value already traversing / unsafe method → nil.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 404 NF\r\n\r\n", target: "/dl?file=doc.pdf", body: "X", status: 404)).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=../etc/passwd", body: "X")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "X", method: "POST")).should be_nil
    end
  end

  # The name list is checked REGARDLESS of the value, so an everyday application parameter in it
  # sent three probes at a large share of all traffic for nothing.
  it "does not treat ordinary application parameters as file parameters" do
    with_store do |store|
      ["/u?name=John", "/l?view=grid", "/l?page=2", "/l?load=more", "/go?url=alpha"].each do |t|
        probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, body: "X")).should be_nil, t
      end
      # A bare identifier under a real file param is an id, not a filename.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/d?doc=1234", body: "X")).should be_nil
      # …but a file-SHAPED value still qualifies under ANY name, so nothing is lost.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/l?page=home.html", body: "X")).should_not be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/go?url=a/b", body: "X")).should_not be_nil
    end
  end

  # `includes?(".js")` fired inside `.json`, and `.md` inside `.mdx`.
  it "requires a real extension boundary, not a substring of a longer one" do
    with_store do |store|
      # `data.jsonp` / `notes.mdx` are not the .js / .md files the old substring test saw — and
      # neither name is a file param, so nothing else qualifies them.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?q=data.jsonp", body: "X")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/a?q=notes.mdx", body: "X")).should be_nil
      # The real extensions still qualify.
      ["/a?q=app.js", "/a?q=data.json", "/a?q=notes.md"].each do |t|
        probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, body: "X")).should_not be_nil, t
      end
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/dl?file=doc.pdf", "/dl?file=secret", "/s?q=hi", "/dl?file=../x",
       "/p?page=home.html&x=1", "http://acme.test/dl?file=a.pdf"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t, body: "X")
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/dl?file=doc.pdf", body: "X", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end
end

describe "Gori::Probe::Active::OpenRedirect" do
  probe = Gori::Probe::Active::OpenRedirect.new
  resp = ->(status : Int32, location : String) do
    head = location.empty? ? "HTTP/1.1 #{status} X\r\n\r\n" : "HTTP/1.1 #{status} X\r\nLocation: #{location}\r\n\r\n"
    Gori::Repeater::Result.new(head.to_slice, Bytes.empty, nil, 1_i64)
  end

  it "plans a probe replacing the redirect-driving parameter with the probe host" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["next"])
      String.new(plan.request).should contain("next=https%3A%2F%2Fgori-redir-probe.example")
    end
  end

  it "mirrors the captured value's encoding (literal :// gets a literal probe URL)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https://acme.test/cb", status: 302)
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain("next=https://gori-redir-probe.example")
    end
  end

  it "flags High when the probe Location follows to the probe host" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      plan = probe.plan(detail).not_nil!
      dets = probe.detections(plan, resp.call(302, "https://gori-redir-probe.example/cb"), detail)
      dets.size.should eq(1)
      dets.first.code.should eq("open_redirect")
      dets.first.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "does not fire on a relative Location, the userinfo trick, or a non-redirect" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, resp.call(302, "/dashboard"), detail).should be_empty
      probe.detections(plan, resp.call(302, "https://gori-redir-probe.example@evil.test/"), detail).should be_empty
      probe.detections(plan, resp.call(200, ""), detail).should be_empty
    end
  end

  it "gates on a 3xx whose Location authority a parameter drives" do
    with_store do |store|
      # Captured 200 → not a redirect.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb")).should be_nil
      # Relative Location that NO parameter accounts for: the only param carries an absolute
      # value, so it cannot be what produced `/home`.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /home\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)).should be_nil
      # A bare "/" must not nominate a parameter: it prefixes every relative Location there is.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /home\r\n\r\n",
        target: "/login?next=%2F", status: 302)).should be_nil
      # Redirect present but no parameter matches its authority.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?foo=bar", status: 302)).should be_nil
    end
  end

  it "gates on a RELATIVE Location a parameter drives, and probes it unencoded" do
    with_store do |store|
      # `/login?next=/dashboard` → `Location: /dashboard` is the dominant open-redirect shape;
      # the rule used to skip it entirely because the captured Location named no authority.
      detail = probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /dashboard\r\n\r\n",
        target: "/login?next=%2Fdashboard", status: 302)
      plan = probe.plan(detail).not_nil!
      plan.params.first.name.should eq("next")
      # This capture arrived percent-encoded, so the app decodes: send the ENCODED probe.
      String.new(plan.request).should contain(Gori::Probe::Active::OpenRedirect::PROBE_VALUE)
      probe.detections(plan, resp.call(302, "https://gori-redir-probe.example/x"), detail)
        .map(&.code).should eq(["open_redirect"])
      # Confirmation is unchanged: only the probe response's OWN authority counts.
      probe.detections(plan, resp.call(302, "/dashboard"), detail).should be_empty
      probe.detections(plan, resp.call(302, "https://gori-redir-probe.example@evil.test/"), detail).should be_empty
    end
  end

  it "sends the LITERAL probe when the relative driver arrived undecoded" do
    with_store do |store|
      # A raw `/dashboard` in the query is the app telling us it does not url-decode this
      # parameter. Sending the percent-encoded probe to it would put a literal
      # `https%3A%2F%2F…` in Location — no authority to parse — and the rule would report
      # clean on an endpoint it never actually asked.
      detail = probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /dashboard\r\n\r\n",
        target: "/login?next=/dashboard", status: 302)
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain(Gori::Probe::Active::OpenRedirect::PROBE_LITERAL)
      req.should_not contain(Gori::Probe::Active::OpenRedirect::PROBE_VALUE)
    end
  end

  it "accepts a relative driver whose Location gained the app's own query" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /dashboard?welcome=1\r\n\r\n",
        target: "/login?next=%2Fdashboard", status: 302)
      probe.plan(detail).not_nil!.params.first.name.should eq("next")
      # …but not one that merely shares a path PREFIX — /dash is a different endpoint.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: /dashboard\r\n\r\n",
        target: "/login?next=%2Fdash", status: 302)).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/login?next=https%3A%2F%2Facme.test%2Fcb", "/go?u=https%3A%2F%2Facme.test%2Fx&t=1",
       "/login?foo=bar"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: https://acme.test/cb\r\n\r\n",
          target: t, status: 302)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      plain = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/login?next=https%3A%2F%2Facme.test%2Fcb")
      probe.dedup_key(plain).should be_nil
    end
  end

  it "surfaces through the full Active.analyze dispatch (plan → send → detections)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 302 Found\r\nLocation: https://acme.test/cb\r\n\r\n",
        target: "/login?next=https%3A%2F%2Facme.test%2Fcb", status: 302)
      backend = FixedBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443),
        "HTTP/1.1 302 Found\r\nLocation: https://gori-redir-probe.example/cb\r\n\r\n")
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, overrides: nil, backend: backend).map(&.code).should contain("open_redirect")
    end
  end
end

describe "Gori::Probe::Active::HostHeaderInjection" do
  probe = Gori::Probe::Active::HostHeaderInjection.new
  body_resp = ->(body : String) do
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice, nil, 1_i64)
  end
  loc_resp = ->(location : String) do
    Gori::Repeater::Result.new("HTTP/1.1 302 F\r\nLocation: #{location}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
  end

  it "plans one authoritative X-Forwarded-Host, dropping any the browser sent" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n",
        target: "/page", req_headers: "X-Forwarded-Host: original.test\r\n")
      req = String.new(probe.plan(detail).not_nil!.request)
      req.should contain("X-Forwarded-Host: gori-host-probe.example")
      req.should_not contain("original.test")
    end
  end

  it "flags Medium when the probe host is reflected as an absolute-URL authority" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n", target: "/page")
      plan = probe.plan(detail).not_nil!
      dets = probe.detections(plan, body_resp.call("<a href='https://gori-host-probe.example/reset?token=abc'>x</a>"), detail)
      dets.size.should eq(1)
      dets.first.code.should eq("host_header_injection")
      dets.first.severity.should eq(Gori::Store::Severity::Medium)
      probe.detections(plan, loc_resp.call("https://gori-host-probe.example/x"), detail).size.should eq(1)
    end
  end

  it "survives a Cache-Control max-age past Int32 (hand-rolled accumulator overflowed)" do
    # `positive_max_age?` accumulated digits into an Int32 with checked arithmetic, so a
    # 10-digit delta-seconds (here a 100-year max-age, which RFC 9111 §1.2.2 says to clamp)
    # raised OverflowError out of `gate`. Nothing rescues between there and the TUI event
    # loop, so the `A` keypress took the whole process down. No "public" token, so the
    # `||` cannot short-circuit before the accumulator runs.
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: max-age=3153600000\r\n\r\n", target: "/page")
      probe.plan(detail).should_not be_nil
    end
  end

  it "does not fire on a bare mention, a path segment, or a longer hostname" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public\r\n\r\n", target: "/page")
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, body_resp.call("see /gori-host-probe.example/ and gori-host-probe.example.evil.com"), detail)
        .should be_empty
    end
  end

  it "gates on a host-reflection-prone captured response" do
    with_store do |store|
      # Cacheable → prone.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n", target: "/p")).should_not be_nil
      # Self-referential (body reflects own Host as an authority) → prone.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/p", body: "<a href='https://acme.test/x'>x</a>")).should_not be_nil
      # Neither cacheable nor self-referential → nil.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\n\r\n", target: "/p", body: "no urls")).should be_nil
      # A cacheable NON-HTML asset (JS/CSS/image) is not a host-reflection surface → not probed.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n\r\n", target: "/app.js", content_type: "application/javascript")).should be_nil
      # A redirect that reflects its own Host is prone regardless of content type.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 302 F\r\nLocation: https://acme.test/next\r\n\r\n", target: "/r", status: 302, content_type: nil)).should_not be_nil
      # Unsafe method not probed by default.
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public\r\n\r\n", target: "/p", method: "POST")).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/page", "/a?x=1", "http://acme.test/b"].each do |t|
        d = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: public\r\n\r\n", target: t)
        probe.dedup_key(d).should eq(probe.plan(d).try(&.dedup_key))
      end
      none = probe_capture_flow(store, "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\n\r\n", target: "/p", body: "nope")
      probe.dedup_key(none).should be_nil
      probe.plan(none).should be_nil
    end
  end
end

describe "Gori::Probe::Active::CrlfInjection" do
  probe = Gori::Probe::Active::CrlfInjection.new

  it "injects an encoded CRLF + per-parameter canary into every query value" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi&r=yo")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["q", "r"])
      req = String.new(plan.request)
      req.should contain("q=hi%0d%0aGori-Probe:%20gq")
      req.should contain("r=yo%0d%0aGori-Probe:%20gq")
    end
  end

  it "flags only the parameter whose canary comes back as a real response header" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi&r=yo")
      plan = probe.plan(detail).not_nil!
      qc = plan.params.find { |p| p.name == "q" }.not_nil!.canary
      result = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nGori-Probe: #{qc}\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      dets = probe.detections(plan, result, detail)
      dets.size.should eq(1)
      dets.first.code.should eq("crlf_injection")
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.evidence.not_nil!.should eq("q")
    end
  end

  it "matches a canary reflected with a trailing suffix (mid-header reflection)" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      qc = plan.params.first.canary
      # The param was reflected mid-header, so the split header carries the canary + a suffix.
      result = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nGori-Probe: #{qc}/dashboard\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
      probe.detections(plan, result, detail).size.should eq(1)
    end
  end

  it "does not fire on a missing or a static (non-canary) Gori-Probe header" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      probe.detections(plan, Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64), detail).should be_empty
      probe.detections(plan, Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nGori-Probe: 1\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64), detail).should be_empty
    end
  end

  it "gates on a safe method with at least one query parameter" do
    with_store do |store|
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")).should be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?q=1", "/s?a=1&b=2", "/s?flag&x=9", "/s"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end
end

describe "Gori::Probe::Active::Ssti" do
  probe = Gori::Probe::Active::Ssti.new
  resp = ->(body : String) { Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice, nil, 1_i64) }

  it "plans two canary-wrapped polyglot probes (49 and 56), URL-encoded" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      plan.params.map(&.name).should eq(["q"])
      plan.followups.size.should eq(1)
      req_a = String.new(plan.request)
      req_a.should contain(plan.params.first.canary)
      req_a.should_not contain("{{")                     # the markers are URL-encoded
      req_a.should_not eq(String.new(plan.followups[0])) # A (7*7) and B (7*8) differ
    end
  end

  it "flags High only when BOTH products evaluate inside the parameter's canary region" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      c = plan.params.first.canary
      dets = probe.detections_all(plan, [resp.call("x#{c}49#{c}y"), resp.call("x#{c}56#{c}y")], detail)
      dets.size.should eq(1)
      dets.first.code.should eq("ssti")
      dets.first.severity.should eq(Gori::Store::Severity::High)
      dets.first.evidence.not_nil!.should eq("q")
    end
  end

  it "does not fire on verbatim reflection, a single product, or a stray number outside the region" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=hi")
      plan = probe.plan(detail).not_nil!
      c = plan.params.first.canary
      # Verbatim echo: the region carries the literal markers, never the products.
      probe.detections_all(plan, [resp.call("#{c}{{7*7}}#{c}"), resp.call("#{c}{{7*8}}#{c}")], detail).should be_empty
      # Only 49 evaluated (B lacks 56) → not confirmed.
      probe.detections_all(plan, [resp.call("#{c}49#{c}"), resp.call("#{c}{{7*8}}#{c}")], detail).should be_empty
      # 49/56 present only OUTSIDE the canary region → ignored.
      probe.detections_all(plan, [resp.call("49 56 #{c}safe#{c} 49"), resp.call("49 56 #{c}safe#{c} 56")], detail).should be_empty
    end
  end

  it "gates on a body-comparable method with query params (POST only under allow_unsafe)" do
    with_store do |store|
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "HEAD")).should be_nil
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")).should be_nil
      unsafe = Gori::Probe::Active::Options.new(allow_unsafe: true)
      probe.plan(probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST"), unsafe).should_not be_nil
    end
  end

  it "dedup_key stays identical to plan.dedup_key (equivalence invariant)" do
    with_store do |store|
      ["/s?q=1", "/s?a=1&b=2", "/s?flag&x=9", "/s"].each do |t|
        detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: t)
        probe.dedup_key(detail).should eq(probe.plan(detail).try(&.dedup_key))
      end
      post = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", target: "/s?q=1", method: "POST")
      probe.dedup_key(post).should be_nil
      probe.plan(post).should be_nil
    end
  end
end
