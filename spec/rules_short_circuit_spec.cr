require "./spec_helper"

# The short-circuit rule op (#511): a Match&Replace rule that ANSWERS a request instead of
# rewriting one. Covers the engine half — the parse, the two body sources, the fail-closed
# stance, and the invariant that a stub rule must never be treated as a rewrite rule.
# The proxy half (framing, keep-alive, the recorded flow) is in proxy_short_circuit_spec.cr.

private SC = Gori::Store::RuleOp::ShortCircuit

private def with_store(&)
  path = File.tempname("gori-short-circuit", ".db")
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

private def get(target = "/admin")
  "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
end

describe Gori::RuleStub do
  it "parses a status line in every accepted spelling and fills the reason in" do
    Gori::RuleStub.parse_head("200 OK").not_nil!.status.should eq(200)
    Gori::RuleStub.parse_head("HTTP/1.1 404 Not Found").not_nil!.status.should eq(404)
    # A bare code gets the registered phrase — a lookup, not a guess about intent.
    String.new(Gori::RuleStub.parse_head("403").not_nil!.bytes).should eq("HTTP/1.1 403 Forbidden\r\n")
    # ...and an explicitly-given reason is kept verbatim, even a non-standard one.
    String.new(Gori::RuleStub.parse_head("200 Totally Fine").not_nil!.bytes)
      .should eq("HTTP/1.1 200 Totally Fine\r\n")
  end

  it "refuses a stub with no status, a non-numeric one, or one out of range" do
    Gori::RuleStub.parse_head("").should be_nil
    Gori::RuleStub.parse_head("OK").should be_nil
    Gori::RuleStub.parse_head("99 Too Small").should be_nil
    Gori::RuleStub.parse_head("600 Too Big").should be_nil
    # A header line with no colon is a typo, not a header — refuse rather than drop it,
    # so the operator finds out at save time instead of from live traffic.
    Gori::RuleStub.parse_head("200 OK\nContent-Type").should be_nil
  end

  it "DROPS Content-Length and Transfer-Encoding from the authored head" do
    # The whole reason: framing is re-derived from the bytes actually sent, so a stub that
    # declares a length it doesn't have cannot desync a keep-alive connection.
    head = Gori::RuleStub.parse_head("200 OK\nContent-Length: 999\nTransfer-Encoding: chunked\nX-Keep: yes\n")
    text = String.new(head.not_nil!.bytes)
    text.should_not contain("Content-Length")
    text.should_not contain("Transfer-Encoding")
    text.should contain("X-Keep: yes")
  end

  it "splits the inline body on the first blank line and keeps its bytes verbatim" do
    stub = "200 OK\nContent-Type: application/json\n\n{\"isAdmin\": true}\n\ntrailing"
    String.new(Gori::RuleStub.inline_body(stub)).should eq("{\"isAdmin\": true}\n\ntrailing")
    # Head-only stub: no blank line at all.
    Gori::RuleStub.inline_body("204 No Content").size.should eq(0)
  end
end

describe Gori::RuleStubBodyCache do
  it "re-reads a body file only after it changes, and reports the change" do
    path = File.tempname("gori-stub-body", ".json")
    File.write(path, "first")
    begin
      cache = Gori::RuleStubBodyCache.new
      String.new(cache.read(path)).should eq("first")
      String.new(cache.read(path)).should eq("first") # served from cache

      # A same-length rewrite is the case an mtime-only OR a size-only check would miss;
      # the cache validates on BOTH, so it must be seen.
      sleep 10.milliseconds
      File.write(path, "SECOND!")
      String.new(cache.read(path)).should eq("SECOND!")
    ensure
      File.delete?(path)
    end
  end

  it "raises rather than returning empty bytes for a missing or oversized file" do
    cache = Gori::RuleStubBodyCache.new
    expect_raises(Gori::Error, /unreadable/) { cache.read("/nonexistent/gori/stub.bin") }
    expect_raises(Gori::Error, /not a regular file/) { cache.read(Dir.tempdir) }
  end
end

describe "Gori::Rules — short-circuit op" do
  it "answers a matching request and reports the stub it built" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/admin", "200 OK\nContent-Type: application/json\n\n{\"isAdmin\": true}", op: SC)

      rules.short_circuits?.should be_true
      stub = rules.short_circuit(get("/admin"), "acme.test").not_nil!
      stub.status.should eq(200)
      stub.error.should be_nil
      String.new(stub.head).should eq("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
      String.new(stub.body).should eq("{\"isAdmin\": true}")

      # A request the pattern does not claim is left alone — no stub, so ClientConn dials.
      rules.short_circuit(get("/public"), "acme.test").should be_nil
    end
  end

  it "honours the host glob and the regex match kind, exactly as a replace rule does" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "^GET /api/v\\d+/me ", "200 OK\n\nstubbed", op: SC,
        match_kind: Gori::Store::MatchKind::Regex, host: "*.acme.test")

      rules.short_circuit(get("/api/v2/me"), "api.acme.test").should_not be_nil
      rules.short_circuit(get("/api/v2/me"), "other.test").should be_nil # out of host scope
      rules.short_circuit(get("/api/me"), "api.acme.test").should be_nil # regex misses
    end
  end

  it "serves body_file instead of the inline body, and picks up an edit to it" do
    path = File.tempname("gori-stub", ".bin")
    File.write(path, "\x89PNG\r\n\x1a\n")
    begin
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "/logo.png", "200 OK\nContent-Type: image/png\n\nIGNORED INLINE BODY", op: SC,
          body_file: path)

        stub = rules.short_circuit(get("/logo.png"), "acme.test").not_nil!
        String.new(stub.body).should eq("\x89PNG\r\n\x1a\n")

        sleep 10.milliseconds
        File.write(path, "edited-on-disk")
        String.new(rules.short_circuit(get("/logo.png"), "acme.test").not_nil!.body)
          .should eq("edited-on-disk")
      end
    ensure
      File.delete?(path)
    end
  end

  it "FAILS CLOSED when the body file is gone — it answers 502, it does not fall through" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/logo.png", "200 OK\n", op: SC, body_file: "/nonexistent/gori/stub.png")

      # nil here would mean "dial the origin", sending a request the operator declared
      # contained. It must be a stub, and it must say what went wrong.
      stub = rules.short_circuit(get("/logo.png"), "acme.test").not_nil!
      stub.status.should eq(502)
      stub.error.should_not be_nil
      String.new(stub.head).should contain("X-Gori-Short-Circuit: error")
    end
  end

  it "keeps a stub rule OUT of every rewrite path and its hot-path counts" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      # The `replacement` here is a whole HTTP response. If a stub rule were ever counted or
      # selected as a head rule, gsub would splice this into live traffic.
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "Host: acme.test", "200 OK\n\npwned", op: SC)

      head = get("/admin")
      rules.rewrite_request(head, "acme.test").should eq(head) # byte-identical
      rules.rewrites_request_body?.should be_false
      rules.rewrites_response_body?.should be_false
      # ...but it IS live for its own seam.
      rules.short_circuits?.should be_true
      rules.active?.should be_true
    end
  end

  it "forces a stub rule to request/head no matter what shape the caller asks for" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body,
        "/admin", "200 OK\n\nok", op: SC)
      rule = rules.rules.first
      rule.target.request?.should be_true
      rule.part.head?.should be_true
    end
  end

  it "stops at the FIRST matching rule — a stub terminates, it does not compose" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/admin", "200 OK\n\nfirst", op: SC)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/admin", "500 Server Error\n\nsecond", op: SC)
      String.new(rules.short_circuit(get("/admin"), "acme.test").not_nil!.body).should eq("first")
    end
  end

  it "goes inert the moment the rule is disabled" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/admin", "200 OK\n\nok", op: SC)
      rules.toggle(rules.rules.first.id)
      rules.short_circuits?.should be_false
      rules.short_circuit(get("/admin"), "acme.test").should be_nil
    end
  end

  it "round-trips the op and body_file through the store" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/admin", "200 OK\n\nok", op: SC, body_file: "/tmp/x.json", name: "admin stub")
      reloaded = Gori::Rules.load(store).rules.first
      reloaded.op.should eq(SC)
      reloaded.op.label.should eq("short_circuit")
      reloaded.body_file.should eq("/tmp/x.json")
      # A persisted stub rule MUST NOT come back as a Replace rule: `from_label`'s else-branch
      # coerces unknown labels to Replace, which would gsub the response text into traffic.
      Gori::Store::RuleOp.from_label("short_circuit").should eq(SC)
    end
  end

  it "previews a stub rule as the flows it WOULD have answered" do
    with_store do |store|
      flow = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/admin", http_version: "HTTP/1.1",
        head: get("/admin")))
      flow.should be > 0

      rules = Gori::Rules.load(store)
      hit = Gori::Store::MatchRule.new(0_i64, true, Gori::Store::RuleTarget::Request,
        Gori::Store::RulePart::Head, "/admin", "200 OK\n\nok", SC)
      miss = Gori::Store::MatchRule.new(0_i64, true, Gori::Store::RuleTarget::Request,
        Gori::Store::RulePart::Head, "/nope", "200 OK\n\nok", SC)
      rules.preview(hit).matched.should eq(1)
      rules.preview(miss).matched.should eq(0)
    end
  end
end
