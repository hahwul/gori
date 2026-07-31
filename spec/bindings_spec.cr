require "./spec_helper"

# Session bindings (#501), slice 1: the extract-rule table, the send-time `$NAME` layer, and
# the injection half inside `Rules#apply_rule`.
#
# The heaviest fixture here is the RuleOp × MatchKind matrix, and it is heavy on purpose:
# resolving `MatchRule#replacement` through `Env` changes the meaning of every existing rule
# containing a `$`, on a persisted, operator-authored table. That is a one-way door, so the
# "no `$` → the identical string, for every op and every match kind" property is pinned for
# each combination rather than argued.

private def with_store(&)
  path = File.tempname("gori-bindings", ".db")
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

# Install a binding layer for the duration of the block, then put back whatever was there.
# `Env.layer` is a per-project global (like `Settings.project_env_vars`), so a spec that
# leaked one would change what every later example thinks `$SESSION` means.
private def with_layer(bindings : Gori::Bindings?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = bindings
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

private def with_env_vars(vars : Hash(String, String), &)
  previous = Gori::Settings.project_env_vars
  Gori::Settings.project_env_vars = vars.to_a.map { |(k, v)| {k, v} }
  Gori::Env.bump_highlight_rev
  begin
    yield
  ensure
    Gori::Settings.project_env_vars = previous
    Gori::Env.bump_highlight_rev
  end
end

# A `Repeater::Result` carrying a response — the only thing an extract rule reads.
private def response_result(head : String, body : String = "") : Gori::Repeater::Result
  bytes = head.to_slice
  parsed = Gori::Proxy::Codec::Http1.parse_response_head(bytes)
  Gori::Repeater::Result.new(bytes, body.to_slice, parsed, 1_i64, nil)
end

private def subject(host : String = "acme.test", target : String = "/login",
                    method : String = "POST", status : Int32? = 200) : Gori::InterceptFilter::Subject
  Gori::InterceptFilter::Subject.new(method: method, host: host, target: target,
    scheme: "https", status: status)
end

describe Gori::Bindings do
  describe "extract rules" do
    it "persists a rule and declares its name" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
        b.rules.size.should eq(1)
        b.declared.should eq(["SESSION"])
        # The RULE persists; the VALUE does not exist yet and never reaches the store.
        Gori::Bindings.load(store).rules.first.name.should eq("SESSION")
        Gori::Bindings.load(store).values.should be_empty
      end
    end

    it "refuses a second writer for one name, and names the rule that has it" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        err = b.add("SESSION", "", Gori::ExtractKind::Header, "authorization")
        err.should_not be_nil
        err.not_nil!.should contain("one name, one writer")
        b.rules.size.should eq(1)
      end
    end

    it "refuses a name that is not a valid $KEY" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("1SESSION", "", Gori::ExtractKind::Cookie, "sid").should_not be_nil
        b.add("has space", "", Gori::ExtractKind::Cookie, "sid").should_not be_nil
        b.add("", "", Gori::ExtractKind::Cookie, "sid").should_not be_nil
        b.rules.should be_empty
      end
    end

    it "refuses a regex descriptor that does not compile" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("TOKEN", "", Gori::ExtractKind::Regex, "(unclosed").should_not be_nil
        b.rules.should be_empty
      end
    end

    it "lets a rule keep its own name when edited" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        id = b.rules.first.id
        b.update(id, "SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
        b.rules.first.match_filter.should eq("path:/login")
      end
    end

    it "stops declaring a disabled rule's name" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.toggle(b.rules.first.id)
        b.declared.should be_empty
      end
    end
  end

  describe "#observe" do
    it "binds a cookie from a matching response" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "status:200 AND path:/login", Gori::ExtractKind::Cookie, "sid")
        raw = response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123; Path=/\r\n\r\n")
        b.observe(raw, subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("abc123")
      end
    end

    it "does not fire when the condition does not match" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid")
        raw = response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n")
        b.observe(raw, subject(target: "/search")).should be_empty
        b.values.should be_empty
      end
    end

    it "respects the rule's host glob" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid", host: "*.acme.test")
        raw = response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n")
        b.observe(raw, subject(host: "evil.test")).should be_empty
        b.observe(raw, subject(host: "api.acme.test")).should eq(["SESSION"])
      end
    end

    it "keeps the previous value on a miss, and says so in the event feed" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=first\r\n\r\n"), subject)
        # A response the rule matched but the extractor found nothing in: the binding must
        # NOT be cleared to "" or nil — the previous value is still the truth about the
        # session, and blanking it would refuse every subsequent send for no reason.
        b.observe(response_result("HTTP/1.1 200 OK\r\nX-Nothing: here\r\n\r\n"), subject).should be_empty
        b.values["SESSION"].should eq("first")
        miss = store.events_after(0, 50).find { |e| e.kind == "extract_miss" }
        miss.should_not be_nil
        miss.not_nil!.message.should contain("$SESSION")
        # The rule and the reason, never the value.
        miss.not_nil!.message.should_not contain("first")
      end
    end

    it "never extracts from an errored send" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        errored = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "connection refused")
        b.observe(errored, subject).should be_empty
      end
    end

    it "drops the old name's value on a rename" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        b.update(b.rules.first.id, "TOKEN", "", Gori::ExtractKind::Cookie, "sid")
        b.values.has_key?("SESSION").should be_false
        b.values.has_key?("TOKEN").should be_false
      end
    end

    it "forgets a value when its rule is deleted" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        b.remove(b.rules.first.id)
        b.values.should be_empty
      end
    end

    it "keeps the value when its rule is merely disabled" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        b.toggle(b.rules.first.id)
        b.values["SESSION"].should eq("abc")
      end
    end
  end

  describe ".mask_preview" do
    it "masks a short value whole rather than half-revealing it" do
      Gori::Bindings.mask_preview("secret").should eq("••••••")
      Gori::Bindings.mask_preview("secret").should_not contain("sec")
    end

    it "shows first/last 4 and the length for a long one" do
      Gori::Bindings.mask_preview("abcdefghijklmnopqrst").should eq("abcd…20…qrst")
    end
  end

  describe "Row#preview" do
    it "never prints an unmasked value" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=supersecrettokenvalue\r\n\r\n"), subject)
        row = b.rows.first
        row.bound?.should be_true
        row.preview.should_not contain("supersecrettokenvalue")
      end
    end
  end
end

describe "Gori::Env — the send-time binding layer" do
  it "does not report a declared name as unresolved at plan-build time" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      with_layer(b) do
        # #525 refuses an unresolved `$NAME` at plan-build. A DECLARED binding is not
        # unresolved — it resolves later, at send — so one syntax keeps one rule.
        Gori::Env.unresolved("Cookie: sid=$SESSION").should be_empty
        Gori::Env.unresolved("Cookie: sid=$NOPE").should eq(["NOPE"])
        # A caller that wants every name back still gets it.
        Gori::Env.unresolved("$SESSION", deferred: nil).should eq(["SESSION"])
      end
    end
  end

  it "reports a declared-but-unbound name at send time, and only a declared one" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      with_layer(b) do
        Gori::Env.unbound("Cookie: sid=$SESSION").should eq(["SESSION"])
        # An unknown `$NOPE` is plan-build's business, not a send seam's — reporting it
        # from both would be the second behaviour for one syntax the design rules out.
        Gori::Env.unbound("Cookie: sid=$NOPE").should be_empty
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        Gori::Env.unbound("Cookie: sid=$SESSION").should be_empty
      end
    end
  end

  it "substitutes only BOUND bindings into wire bytes, byte-identically otherwise" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n"), subject)
      with_layer(b) do
        wire = "GET /a HTTP/1.1\r\nCookie: sid=$SESSION\r\n\r\n".to_slice
        String.new(Gori::Env.expand_bindings(wire)).should eq("GET /a HTTP/1.1\r\nCookie: sid=abc123\r\n\r\n")
        # No token → the SAME slice back, not a copy.
        plain = "GET /a HTTP/1.1\r\n\r\n".to_slice
        Gori::Env.expand_bindings(plain).should be(plain)
      end
    end
  end

  it "leaves env vars alone at send time so #356's one-expansion invariant survives" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
      with_env_vars({"HOSTNAME" => "acme.test"}) do
        with_layer(b) do
          # `$HOSTNAME` was already expanded at plan-build; the send pass must not touch it
          # (nor re-expand a value that happens to contain a `$`).
          out = String.new(Gori::Env.expand_bindings("Host: $HOSTNAME\r\nCookie: $SESSION".to_slice))
          out.should eq("Host: $HOSTNAME\r\nCookie: abc")
        end
      end
    end
  end

  it "masks a bound value everywhere mask_secrets is already called" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=supersecret\r\n\r\n"), subject)
      with_layer(b) do
        Gori::Env.mask_secrets("Cookie: sid=supersecret").should eq("Cookie: sid=$SESSION")
      end
    end
  end

  it "paints a bound token as known and an unbound one as unknown" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      with_layer(b) do
        Gori::Env.token_regions("x $SESSION").map(&.[2]).should eq([false])
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        Gori::Env.token_regions("x $SESSION").map(&.[2]).should eq([true])
      end
    end
  end
end

describe "Gori::Rules — replacement resolution (#501)" do
  it "resolves a bound binding into a header value" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc123\r\n\r\n"), subject)
      with_layer(b) do
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "Cookie", "sid=$SESSION", Gori::Store::RuleOp::SetHeader)
        head = "GET / HTTP/1.1\r\nHost: a\r\nCookie: sid=stale\r\n\r\n".to_slice
        String.new(rules.rewrite_request(head, "a")).should contain("Cookie: sid=abc123")
      end
    end
  end

  it "resolves a static env var, which simply did not work before" do
    with_store do |store|
      with_env_vars({"TRACE" => "on"}) do
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "X-Trace", "$TRACE", Gori::Store::RuleOp::AddHeader)
        head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
        String.new(rules.rewrite_request(head, "a")).should contain("X-Trace: on")
      end
    end
  end

  it "does not apply a rule whose binding has no value, and never ships the literal $NAME" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      with_layer(b) do
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "Authorization", "Bearer $SESSION", Gori::Store::RuleOp::SetHeader)
        head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
        out = String.new(rules.rewrite_request(head, "a"))
        out.should_not contain("$SESSION")
        out.should_not contain("Authorization")
        out.should eq(String.new(head))
        # And the operator hears about it, with the gate NAMED (#491) and no value in sight.
        ev = store.events_after(0, 50).find { |e| e.kind == "unbound" }
        ev.should_not be_nil
        ev.not_nil!.message.should contain("$SESSION")
      end
    end
  end

  it "leaves an undeclared $NAME literal, so a pre-existing rule keeps its meaning" do
    with_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-Cost", "$NOT_A_THING", Gori::Store::RuleOp::AddHeader)
      head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
      String.new(rules.rewrite_request(head, "a")).should contain("X-Cost: $NOT_A_THING")
    end
  end

  describe "the regex-replacement hazard" do
    # A binding value is SERVER-CONTROLLED and, for MatchKind::Regex, the replacement string
    # is interpreted by `gsub`: Crystal reads `\1`, `\0` and `\k<name>` in one. A token
    # containing `\1` would therefore splice a capture group into the wire bytes, and one
    # containing `\k<x>` raises. This is the finding a reviewer would miss, so it is pinned
    # from BOTH ends: the escaper in isolation, and the whole rewrite path.

    it "escapes a backslash capture reference in a substituted value" do
      Gori::Rules.escape_backrefs("tok\\1en").should eq("tok\\\\1en")
      # Nothing to escape → the identical String, so the common case allocates nothing.
      plain = "abc"
      Gori::Rules.escape_backrefs(plain).should be(plain)
    end

    it "does not let a server-controlled \\1 in a token become a capture group" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        # The origin sets a cookie whose VALUE is a capture reference.
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=\\1\r\n\r\n"), subject)
        b.values["SESSION"].should eq("\\1")
        with_layer(b) do
          rules = Gori::Rules.load(store)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "sid=(\\w+)", "sid=$SESSION", Gori::Store::RuleOp::Replace,
            Gori::Store::MatchKind::Regex)
          head = "GET / HTTP/1.1\r\nCookie: sid=CAPTUREME\r\n\r\n".to_slice
          out = String.new(rules.rewrite_request(head, "a"))
          # The token goes out LITERALLY. Before the escape it read back the capture group
          # and the header became `sid=CAPTUREME`, i.e. the origin chose the wire bytes.
          out.should contain("Cookie: sid=\\1")
          out.should_not contain("sid=CAPTUREME")
        end
      end
    end

    it "does not let a \\k<name> in a token raise the rewrite into a passthrough" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=\\k<oops>\r\n\r\n"), subject)
        with_layer(b) do
          rules = Gori::Rules.load(store)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "sid=(\\w+)", "sid=$SESSION", Gori::Store::RuleOp::Replace,
            Gori::Store::MatchKind::Regex)
          head = "GET / HTTP/1.1\r\nCookie: sid=x\r\n\r\n".to_slice
          String.new(rules.rewrite_request(head, "a")).should contain("Cookie: sid=\\k<oops>")
        end
      end
    end

    it "still translates the operator's own $1 capture ref" do
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "Host: (\\w+)\\.test", "Host: $1.example", Gori::Store::RuleOp::Replace,
          Gori::Store::MatchKind::Regex)
        head = "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
        String.new(rules.rewrite_request(head, "acme.test")).should contain("Host: acme.example")
      end
    end

    it "reads $$ as an escaped prefix, so $$SESSION is the literal text" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        with_layer(b) do
          rules = Gori::Rules.load(store)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "X-Literal", "$$SESSION", Gori::Store::RuleOp::AddHeader)
          head = "GET / HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
          out = String.new(rules.rewrite_request(head, "a"))
          out.should contain("X-Literal: $SESSION")
          out.should_not contain("abc")
        end
      end
    end
  end

  describe "the one-way door" do
    # Every RuleOp × MatchKind, with a replacement carrying no `$`: the bytes must come back
    # exactly as they did before replacements were resolved through `Env`.
    {% for op in ["Replace", "AddHeader", "SetHeader", "RemoveHeader"] %}
      {% for kind in ["Literal", "Regex"] %}
        it "is byte-identical for {{ op.id }} × {{ kind.id }} when the replacement has no $" do
          with_store do |store|
            rules = Gori::Rules.load(store)
            rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
              "X-Old", "plain-value", Gori::Store::RuleOp::{{ op.id }},
              Gori::Store::MatchKind::{{ kind.id }})
            head = "GET / HTTP/1.1\r\nHost: a\r\nX-Old: keep\r\n\r\n".to_slice
            before = String.new(rules.rewrite_request(head, "a"))
            # Re-running with a live (but irrelevant) binding layer must not change it.
            b = Gori::Bindings.load(store)
            b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
            with_layer(b) do
              String.new(rules.rewrite_request(head, "a")).should eq(before)
            end
          end
        end
      {% end %}
    {% end %}

    it "leaves a body replacement's non-UTF-8 bytes untouched" do
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body,
          "needle", "replaced")
        body = Bytes[0xFF, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0xFE] # \xFF needle \xFE
        rewritten = rules.rewrite_request_body(body, "a")
        rewritten[0].should eq(0xFF_u8)
        rewritten[-1].should eq(0xFE_u8)
        String.new(rewritten).should contain("replaced")
      end
    end
  end
end

describe "Gori::Store — extract_rules" do
  it "round-trips every descriptor kind" do
    with_store do |store|
      Gori::ExtractKind.values.each do |kind|
        store.insert_extract_rule("N#{kind}", "path:/x", kind, "sel", 1, 9, "*.acme.test")
      end
      rows = store.extract_rules
      rows.size.should eq(Gori::ExtractKind.values.size)
      rows.map(&.kind).to_set.should eq(Gori::ExtractKind.values.to_set)
      row = rows.first
      row.match_filter.should eq("path:/x")
      row.host.should eq("*.acme.test")
      row.token_loc.pos_start.should eq(1)
      row.token_loc.pos_end.should eq(9)
    end
  end

  it "marks body-scoped kinds, which is what slice 2 will count to buffer a response" do
    with_store do |store|
      mk = ->(k : Gori::ExtractKind) { Gori::Store::ExtractRule.new(1_i64, true, "N", "", k) }
      mk.call(Gori::ExtractKind::Cookie).body_scoped?.should be_false
      mk.call(Gori::ExtractKind::Header).body_scoped?.should be_false
      mk.call(Gori::ExtractKind::Regex).body_scoped?.should be_true
      mk.call(Gori::ExtractKind::JsonPath).body_scoped?.should be_true
      mk.call(Gori::ExtractKind::Position).body_scoped?.should be_true
    end
  end
end
