require "../spec_helper"

# The short-circuit rule op (#511): a Match&Replace rule that ANSWERS a request instead of
# rewriting one. Covers the engine half — the parse, the two body sources, the fail-closed
# stance, and the invariant that a stub rule must never be treated as a rewrite rule.
# The proxy half (framing, keep-alive, the recorded flow) is in proxy_short_circuit_spec.cr.

private SC = Gori::Store::RuleOp::ShortCircuit

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

  it "takes the FIRST blank line even when the body carries a CRLFCRLF of its own" do
    # A stub authored in the TUI is LF-joined (`TextArea#text`), so a body that embeds a
    # captured message / multipart part puts a `\r\n\r\n` AFTER the real separator. Scanning
    # for the CRLF spelling first swallowed the leading body lines into the head, which then
    # either failed to parse (a body line has no colon) or — worse — promoted a body line
    # that happened to look like a header into a real one.
    stub = "200 OK\nContent-Type: message/http\n\nGET / HTTP/1.1\r\nX-Injected: yes\r\n\r\nnested"
    String.new(Gori::RuleStub.inline_body(stub))
      .should eq("GET / HTTP/1.1\r\nX-Injected: yes\r\n\r\nnested")
    head = Gori::RuleStub.parse_head(stub).not_nil!
    head.status.should eq(200)
    String.new(head.bytes).should_not contain("X-Injected")
  end

  it "still takes a CRLF-authored head's own separator" do
    stub = "200 OK\r\nContent-Type: text/plain\r\n\r\nbody\n\ntail"
    String.new(Gori::RuleStub.inline_body(stub)).should eq("body\n\ntail")
    String.new(Gori::RuleStub.parse_head(stub).not_nil!.bytes)
      .should eq("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n")
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
        head: get("/admin"), source: Gori::FlowSource::Kind::Proxy))
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

# The short-circuit SUB-KIND (#1237): where the answer comes from — inline, file, dir, fault —
# and its parameters. This half is the model and the one validator every surface calls; the
# proxy half is in spec/proxy/short_circuit_spec.cr.
private alias RK = Gori::Store::RespondKind

describe Gori::Store::RespondArgs do
  it "reads an empty column as every default" do
    args = Gori::Store::RespondArgs.parse("").as(Gori::Store::RespondArgs)
    args.strip_prefix.should eq("")
    args.fallthrough?.should be_false
    args.fault.should be_nil
    args.delay_ms.should eq(0)
    args.hang_ms.should eq(Gori::Store::RespondArgs::DEFAULT_HANG_MS)
  end

  it "reads every key it knows" do
    args = Gori::Store::RespondArgs.parse(
      %({"strip_prefix":"/static/","fallthrough":true,"fault":"hang","delay_ms":250,"hang_ms":1000})
    ).as(Gori::Store::RespondArgs)
    args.strip_prefix.should eq("/static/")
    args.fallthrough?.should be_true
    args.fault.should eq(Gori::Store::FaultKind::Hang)
    args.delay_ms.should eq(250)
    args.hang_ms.should eq(1000)
  end

  # The #1242 contract applied to this field: what this binary cannot read comes back as a
  # REASON, never as a rule that silently lost the part it did not understand — and never as a
  # raise, because this runs inside `Rules#refresh` on the peer tick.
  it "answers a reason, never a raise, for anything it cannot read" do
    {
      %({"throttle":5}),
      %({"fault":"slowloris"}),
      %({"fault":3}),
      %({"fallthrough":"yes"}),
      %({"delay_ms":-1}),
      %({"delay_ms":120001}),
      %({"delay_ms":99999999999999999999}),
      %({"hang_ms":1.5}),
      %(["fault"]),
      %({not json),
    }.each do |raw|
      Gori::Store::RespondArgs.parse(raw).should be_a(String)
    end
  end

  it "stores only what differs from the defaults" do
    Gori::Store::RespondArgs.new.to_stored.should eq("")
    Gori::Store::RespondArgs.new(fault: Gori::Store::FaultKind::Reset, delay_ms: 500).to_stored
      .should eq(%({"fault":"reset","delay_ms":500}))
  end
end

describe "Gori::RuleStub.respond_error" do
  it "accepts each sub-kind in its own shape" do
    Gori::RuleStub.respond_error(RK::Inline, "200 OK\n\nhi", "", "").should be_nil
    Gori::RuleStub.respond_error(RK::File, "200 OK", "/tmp/x.json", "").should be_nil
    Gori::RuleStub.respond_error(RK::Dir, "", "/srv/js", %({"strip_prefix":"/static/","fallthrough":true})).should be_nil
    Gori::RuleStub.respond_error(RK::Dir, "200 OK\nCache-Control: no-store", "/srv/js", "").should be_nil
    Gori::RuleStub.respond_error(RK::Fault, "", "", %({"fault":"reset","delay_ms":100})).should be_nil
    Gori::RuleStub.respond_error(RK::Fault, "", "", %({"fault":"hang","hang_ms":2000})).should be_nil
    Gori::RuleStub.respond_error(RK::Inline, "200 OK", "", %({"delay_ms":50})).should be_nil
  end

  it "refuses a shape the proxy could only fail on" do
    {
      {RK::Inline, "nope", "", ""},                             # unparseable head
      {RK::Inline, "200 OK", "/tmp/x", ""},                     # inline with a file
      {RK::File, "200 OK", "", ""},                             # file without one
      {RK::Dir, "", "", ""},                                    # dir without a directory
      {RK::Dir, "200 OK\n\nbody", "/srv", ""},                  # a dir template with a body
      {RK::Dir, "", "/srv", %({"strip_prefix":"/static"})},     # prefix not closed by /
      {RK::Dir, "", "/srv", %({"strip_prefix":"static/"})},     # prefix not rooted
      {RK::Fault, "", "", ""},                                  # no fault kind
      {RK::Fault, "200 OK", "", %({"fault":"close"})},          # a fault that answers
      {RK::Fault, "", "/tmp/x", %({"fault":"close"})},          # a fault with a body file
      {RK::Inline, "200 OK", "", %({"fallthrough":true})},      # fall-through off dir
      {RK::Inline, "200 OK", "", %({"fault":"close"})},         # a fault kind off fault
      {RK::Fault, "", "", %({"fault":"close","hang_ms":1000})}, # a hang bound off hang
      {RK::Inline, "200 OK", "", %({"future":1})},              # a key it cannot read
    }.each do |(respond, repl, body_file, args)|
      Gori::RuleStub.respond_error(respond, repl, body_file, args).should_not be_nil
    end
  end
end

describe "Gori::Rules — short-circuit sub-kind" do
  it "round-trips respond and its args through the store" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "GET /static/", "", op: SC, body_file: "/srv/js", respond: RK::Dir,
        respond_args: %({"strip_prefix":"/static/"}))
      rule = Gori::Rules.load(store).rules.first
      rule.respond.should eq(RK::Dir)
      rule.args.strip_prefix.should eq("/static/")
      rule.inert?.should be_false
    end
  end

  it "infers a file stub from a body file when no sub-kind is named" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/logo", "200 OK", op: SC, body_file: "/tmp/logo.png")
      Gori::Rules.load(store).rules.first.respond.should eq(RK::File)
    end
  end

  it "makes a dir path absolute once, for every surface" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "GET /s/", "", op: SC, body_file: "~/mock-root", respond: RK::Dir)
      rules.rules.first.body_file.should eq(File.expand_path("~/mock-root", home: true))
    end
  end

  # nil KEEPS the rule's sub-kind: a caller that does not speak of it must not turn a fault
  # rule back into an inline stub by omission.
  it "keeps the sub-kind on an update that does not name it, and drops it with the op" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/pay", "", op: SC, respond: RK::Fault, respond_args: %({"fault":"reset"}))
      id = rules.rules.first.id
      rules.update(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/pay/v2", "", op: SC).should be_true
      rule = rules.rules.first
      rule.pattern.should eq("/pay/v2")
      rule.respond.should eq(RK::Fault)
      rule.args.fault.should eq(Gori::Store::FaultKind::Reset)

      # An op that reads none of the three drops them, so switching back later cannot
      # resurrect a fault the operator no longer sees.
      rules.update(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-A", "b", op: Gori::Store::RuleOp::SetHeader).should be_true
      rule = rules.rules.first
      rule.respond.should eq(RK::Inline)
      rule.respond_args.should eq("")
    end
  end

  it "keeps a rule with a sub-kind or an arg it cannot read INERT, and says why" do
    with_store do |store|
      label = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/a", "", op: SC)
      arg = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/b", "", op: SC, respond: "fault", respond_args: %({"fault":"reset"}))
      store.@db.exec("UPDATE match_rules SET respond = 'script' WHERE id = ?", label)
      store.@db.exec(%(UPDATE match_rules SET respond_args = '{"fault":"reset","throttle":9}' WHERE id = ?), arg)

      rows = store.match_rules
      a = rows.find! { |r| r.id == label }
      a.respond_label.should eq("script")
      a.inert?.should be_true
      a.inert_reason.not_nil!.should contain("respond \"script\"")
      b = rows.find! { |r| r.id == arg }
      b.respond_args.should eq(%({"fault":"reset","throttle":9})) # raw, for a write-back
      b.inert?.should be_true
      b.inert_reason.not_nil!.should contain("throttle")

      engine = Gori::Rules.load(store)
      engine.short_circuits?.should be_false
      engine.short_circuit(get("/a"), "acme.test").should be_nil
      engine.update(label, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "/a", "200 OK", op: SC).should be_false
    end
  end

  it "ignores respond fields on an op that never reads them" do
    rule = Gori::Store::MatchRule.new(1_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "X-A", "b", Gori::Store::RuleOp::SetHeader,
      respond_args: %({"future":1}))
    rule.inert?.should be_false
  end
end
