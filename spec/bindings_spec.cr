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

    # The check belongs to this chokepoint and not to one surface's argument parsing: the CLI
    # calls `Bindings` rather than the store precisely so it "gets the SAME refusals the TUI
    # and MCP do", and while the range test lived in the MCP tool layer alone that was false —
    # a `kind=position` rule with no range saved from the TUI and the CLI and could never bind
    # (`TokenExtract.position` returns nil for `hi <= lo`), missing forever with no reason given.
    it "refuses a position descriptor whose range cannot select anything" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("A", "", Gori::ExtractKind::Position).to_s.should contain("byte range")
        b.add("B", "", Gori::ExtractKind::Position, "", 32, 32).to_s.should contain("byte range")
        b.add("C", "", Gori::ExtractKind::Position, "", 40, 8).to_s.should contain("byte range")
        store.extract_rules.should be_empty
        # A real range still saves, and the other kinds never consult the ints.
        b.add("D", "", Gori::ExtractKind::Position, "", 0, 32).should be_nil
        b.add("E", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        # An UPDATE takes the same refusal, so a good rule cannot be edited into a dead one.
        id = b.rules.first.id
        b.update(id, "D", "", Gori::ExtractKind::Position, "", 0, 0).to_s.should contain("byte range")
        b.rules.first.pos_end.should eq(32)
      end
    end

    # A binding value is the ORIGIN'S, not the operator's, and it is spliced into a request
    # gori then sends — `Rules#substitute` writes it straight into `Authorization: <value>`.
    # So `abc\r\nX-Admin: true` forged a second header line and `abc\r\n\r\nGET /…` forged a
    # whole second request onto a pooled keep-alive upstream. `escape_backrefs` already
    # covers this value being re-read by `gsub`'s replacement grammar; the message boundary
    # is the other half, and `Import::Builder` guards exactly it on the sibling path.
    # It BINDS — a CR/LF in a body forges nothing, and `Env.expand_bindings` documents body
    # injection as a designed case (a PEM block, a SAML assertion, a formatted JSON
    # sub-document). What is refused is the HEAD half, at the injection site.
    it "binds a multi-line value but withholds it from the head" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
        # A JSON-escaped CRLF: the origin's own bytes, decoded into a real CR LF by the
        # extractor — which is exactly how it would reach a header line.
        b.observe(response_result(head, %({"token":"abc\\r\\nX-Admin: true"})), subject)
          .should eq(["SESSION"])
        b.bound?("SESSION").should be_true

        with_layer(b) do
          wire = "GET /a HTTP/1.1\r\nCookie: sid=$SESSION\r\n\r\nbody=$SESSION"
          out = String.new(Gori::Env.expand_bindings(wire.to_slice))
          # Head: left LITERAL, so the forged header line never exists and the operator can
          # see why the request failed.
          out.should contain("Cookie: sid=$SESSION")
          out.should_not contain("X-Admin: true\r\nCookie")
          # Body: substituted, newline and all.
          out.should contain("body=abc\r\nX-Admin: true")
        end
      end
    end

    it "withholds a boundary-forging value from a header rule, not from a body rule" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"token":"a\\r\\nX-Evil: 1"})),
          subject).should eq(["SESSION"])
        with_layer(b) do
          rules = Gori::Rules.new(store, store.match_rules)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "GET",
            "$SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
            "auth", "", "")
          req = "GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
          # The rule does not apply at all, exactly as it does not for an unbound name —
          # rather than writing a second header line the origin would read as its own.
          String.new(rules.rewrite_request(req, "acme.test")).should_not contain("X-Evil")
        end
      end
    end

    # The refusal above is right and it was SILENT: no header on the wire, no event, no log
    # line, no advisory, no status. `substitute` had two nil-returns meaning opposite things
    # and one reporter that only understood the first — `report_unbound` computes
    # `Env.unbound(replacement)` and returns when it is empty, and a BOUND name is by
    # definition not unbound. So an origin minting a cookie with a stray CR in it disarmed
    # every head-scoped injection rule the operator had configured, invisibly, and every
    # later request went out unauthenticated while gori reported clean sends.
    describe "the boundary refusal names itself" do
      # One helper, three byte classes: the guard is CR/LF/NUL and each has to be named on
      # its own, because "invalid" is not something an operator can act on.
      {"\\r" => "CR", "\\n" => "LF", "\\u0000" => "NUL"}.each do |escape, byte_class|
        it "writes a named event when the value carries #{byte_class}" do
          with_store do |store|
            b = Gori::Bindings.load(store)
            b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
            b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"token":"a#{escape}b"})),
              subject).should eq(["SESSION"])
            with_layer(b) do
              rules = Gori::Rules.new(store, store.match_rules)
              rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
                "$SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
                "inject", "", "")
              req = "GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
              rules.rewrite_request(req, "acme.test")

              ev = store.events_after(0, 50).find { |e| e.kind == "boundary_refused" }
              ev.should_not be_nil
              ev = ev.not_nil!
              ev.level.should eq("warn")
              # It names the RULE, the BINDING and the byte class — and never the value.
              ev.message.should contain(%("inject"))
              ev.message.should contain("$SESSION")
              ev.message.should contain(byte_class)
              ev.message.should contain("forge a message boundary")
              # And the VALUE never reaches the feed, not even the byte that triggered it.
              ev.message.each_byte.none? { |x| x == 0x0d_u8 || x == 0x0a_u8 || x == 0x00_u8 }
                .should be_true
              # The rule still did not apply. A named refusal is not a licence to send.
              String.new(rules.rewrite_request(req, "acme.test")).should_not contain("X-Auth:")
            end
          end
        end
      end

      # The COMPLEMENT of the guard's own condition. A horizontal tab is a legal header-value
      # byte and forges nothing, so it must pass byte-exact and say nothing at all — an
      # over-wide guard here would be the same silent disarming with a different trigger.
      it "does not fire for a TAB, which the guard deliberately allows" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
          b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"token":"a\\tb"})),
            subject).should eq(["SESSION"])
          with_layer(b) do
            rules = Gori::Rules.new(store, store.match_rules)
            rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
              "$SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
              "inject", "", "")
            out = String.new(rules.rewrite_request("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
              "acme.test"))
            out.should contain("X-Auth: a\tb")
            store.events_after(0, 50).any? { |e| e.kind == "boundary_refused" }.should be_false
          end
        end
      end

      # The other complement, and the reason the guard is at the injection site rather than at
      # extraction: the SAME value through a BODY rule forges nothing and is the designed case.
      it "does not fire for a body-scoped rule carrying the same value" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
          b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"token":"a\\r\\nb"})),
            subject).should eq(["SESSION"])
          with_layer(b) do
            rules = Gori::Rules.new(store, store.match_rules)
            rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body, "MARK",
              "$SESSION", Gori::Store::RuleOp::Replace, Gori::Store::MatchKind::Literal,
              "inject-body", "", "")
            String.new(rules.rewrite_request_body("x=MARK".to_slice, "acme.test"))
              .should eq("x=a\r\nb")
            store.events_after(0, 50).any? { |e| e.kind == "boundary_refused" }.should be_false
          end
        end
      end

      # The THIRD branch of `head_scoped?`, and the one the finding left uncovered: a WebSocket
      # frame is all payload, there is no head in it for a CR/LF to forge a line into, and
      # `Env.expand_bindings(String)` maps `part: Ws` to `guard_boundary: false` for exactly
      # that reason. So the value must reach the frame intact and say nothing.
      it "does not fire for a ws-scoped rule carrying the same value" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
          b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"token":"a\\r\\nb"})),
            subject).should eq(["SESSION"])
          with_layer(b) do
            rules = Gori::Rules.new(store, store.match_rules)
            rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Ws, "MARK",
              "$SESSION", Gori::Store::RuleOp::Replace, Gori::Store::MatchKind::Literal,
              "inject-ws", "", "")
            String.new(rules.rewrite_ws_out("x=MARK".to_slice, "acme.test")).should eq("x=a\r\nb")
            store.events_after(0, 50).any? { |e| e.kind == "boundary_refused" }.should be_false
          end
        end
      end

      # The refusal the reporter DID understand must keep its exact sentence — it is the one
      # every surface already reads, and the two now share a reporter.
      it "leaves the unbound sentence alone" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
          with_layer(b) do
            rules = Gori::Rules.new(store, store.match_rules)
            rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
              "$SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
              "inject", "", "")
            rules.rewrite_request("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, "acme.test")
            events = store.events_after(0, 50)
            events.any? { |e| e.kind == "boundary_refused" }.should be_false
            ev = events.find { |e| e.kind == "unbound" }.not_nil!
            ev.message.should eq(%(rewrite rule "inject" not applied: $SESSION is not bound yet))
          end
        end
      end

      # Same dedupe as the unbound half: one row per (rule, binding revision), or a rule
      # injecting into every proxied request writes one store row per message.
      it "says it once per rule per binding revision, not once per message" do
        with_store do |store|
          b = Gori::Bindings.load(store)
          b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.token").should be_nil
          b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"token":"a\\r\\nb"})), subject)
          with_layer(b) do
            rules = Gori::Rules.new(store, store.match_rules)
            rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
              "$SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
              "inject", "", "")
            req = "GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
            5.times { rules.rewrite_request(req, "acme.test") }
            store.events_after(0, 50).count { |e| e.kind == "boundary_refused" }.should eq 1
          end
        end
      end
    end

    # Binding values resolve at SEND time, after every plan builder has already framed the
    # request. Without this the declared length described the UNEXPANDED body: on a pipelined
    # send-group the origin read the declared prefix and the remainder became the front of the
    # NEXT request line — gori desyncing its own connection and putting the session token on
    # the wire as a method.
    it "moves the Content-Length by what a body substitution added" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("CSRF", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"t":"TOKEN-0123456789abcdef"})),
          subject).should eq(["CSRF"])
        with_layer(b) do
          wire = "POST /a HTTP/1.1\r\nHost: acme.test\r\nContent-Length: 10\r\n\r\ncsrf=$CSRF"
          out = String.new(Gori::Env.expand_bindings(wire.to_slice))
          body = out.split("\r\n\r\n", 2)[1]
          body.should eq("csrf=TOKEN-0123456789abcdef")
          # 10 + (27 - 10) = 27, which is the body actually sent.
          out.should contain("Content-Length: 27")
        end
      end
    end

    # A DELTA, not a resync: an operator with auto-Content-Length off authored the mismatch as
    # their payload (a smuggling probe), and re-syncing would silently destroy it.
    it "preserves a deliberate Content-Length mismatch's offset" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("T", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"t":"abcdef"})), subject)
        with_layer(b) do
          # Declared 4 for a 3-byte body: an offset of -(-1)… i.e. 1 MORE than the body.
          wire = "POST /a HTTP/1.1\r\nContent-Length: 4\r\n\r\n$T"
          out = String.new(Gori::Env.expand_bindings(wire.to_slice))
          out.split("\r\n\r\n", 2)[1].should eq("abcdef") # 6 bytes, was 2
          out.should contain("Content-Length: 8")         # 4 + 4, offset preserved
        end
      end
    end

    # Everything outside the digit span is the operator's payload on this path: header casing,
    # the space after the colon and a leading zero are live smuggling / WAF-bypass variables,
    # and an obs-folded `Content-Length` under another header is the whole content of an
    # obfuscated-framing probe. The shift runs unconditionally with no auto-CL opt-out, so it
    # has to leave all of that byte-exact.
    it "moves only the digits, never the operator's framing bytes" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("T", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"t":"0123456789"})), subject)
        with_layer(b) do
          shift = ->(head : String) { String.new(Gori::Env.expand_bindings("#{head}\r\n$T".to_slice)) }
          # Spelling and spacing survive; only the number moves (2 → 10, a +8 body delta).
          shift.call("POST /a HTTP/1.1\r\ncontent-length: 2\r\n").should contain("content-length: 10")
          shift.call("POST /a HTTP/1.1\r\nCONTENT-LENGTH: 2\r\n").should contain("CONTENT-LENGTH: 10")
          shift.call("POST /a HTTP/1.1\r\nContent-Length:2\r\n").should contain("Content-Length:10")
          # An obs-fold continuation belongs to the header ABOVE it and is invisible to a
          # strict parser — promoting or editing it would send a different probe than authored.
          folded = shift.call("POST /a HTTP/1.1\r\nX-Note: see\r\n Content-Length: 2\r\n")
          folded.should contain("X-Note: see\r\n Content-Length: 2\r\n")
        end
      end
    end

    # A MIXED-EOL head is itself a parser-discrepancy probe. Splitting the whole head on one
    # spelling glued three lines into one, so the shift silently did nothing.
    it "shifts through a mixed-EOL head" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("T", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"t":"0123456789"})), subject)
        with_layer(b) do
          wire = "POST /a HTTP/1.1\nX-Inj: v\r\nContent-Length: 2\nX-Other: keep\n\n$T"
          out = String.new(Gori::Env.expand_bindings(wire.to_slice))
          out.should contain("Content-Length: 10")
          out.should contain("X-Other: keep") # nothing else moved
          out.should contain("X-Inj: v\r\n")  # the CRLF line kept its own terminator
        end
      end
    end

    # Chunked framing lives in the BODY's chunk-size lines, which gori will not rewrite — that
    # would replace the operator's framing payload. So the head is left exactly as authored
    # (`Fuzz::ContentLength.sync` does the same) and the caller warns rather than going quiet.
    it "leaves a chunked head alone rather than bumping a stray Content-Length" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("T", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"t":"0123456789"})), subject)
        with_layer(b) do
          wire = "POST /a HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n$T\r\n0\r\n\r\n"
          out = String.new(Gori::Env.expand_bindings(wire.to_slice))
          out.should contain("Content-Length: 2\r\n") # untouched
          out.should contain("2\r\n0123456789\r\n")   # the body still substituted
        end
      end
    end

    it "leaves a head-only substitution's Content-Length alone" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("S", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", %({"t":"longvalue"})), subject)
        with_layer(b) do
          wire = "POST /a HTTP/1.1\r\nCookie: sid=$S\r\nContent-Length: 4\r\n\r\nbody"
          out = String.new(Gori::Env.expand_bindings(wire.to_slice))
          out.should contain("Cookie: sid=longvalue")
          out.should contain("Content-Length: 4") # the body did not move
        end
      end
    end

    # A DIAL TUPLE cannot defer: it is frozen into the plan, the ConnPool is built on it and
    # the Layer-1 scope verdict was taken against it. Left deferred, `$SESSION` shipped as the
    # literal host — every send failing DNS, and `Outbound.scope_url` asked about
    # `https://$SESSION/a`, which no rule can match, so the run was refused as out-of-scope:
    # a refusal naming the wrong gate.
    it "refuses a declared binding in a dial target at plan-build" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        with_layer(b) do
          # Bound or not makes no difference — the tuple is read once, before any send.
          b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
          scope = Gori::Scope.load(store)
          err = expect_raises(Gori::Repeater::PlanError) do
            Gori::Repeater::Plan.build(
              Gori::Repeater::PlanOptions.new(["GET /a HTTP/1.1\r\nHost: x\r\n\r\n".to_slice],
                target: "https://$SESSION/a"), Gori::Outbound.cli(scope, false))
          end
          err.message.to_s.should contain("SESSION")
          # The SNI is the same kind of field and takes the same refusal — with the SAME
          # declared name, so this is the deferral being closed and not the pre-existing
          # unknown-key refusal.
          expect_raises(Gori::Repeater::PlanError, /SESSION/) do
            Gori::Repeater::Plan.build(
              Gori::Repeater::PlanOptions.new(["GET /a HTTP/1.1\r\nHost: x\r\n\r\n".to_slice],
                target: "https://acme.test/a", sni: "$SESSION"), Gori::Outbound.cli(scope, false))
          end
          # …while a request BODY keeps its deferral: that one IS re-scanned at send.
          Gori::Repeater::Plan.build(
            Gori::Repeater::PlanOptions.new(["POST /a HTTP/1.1\r\nHost: x\r\n\r\nt=$SESSION".to_slice],
              target: "https://acme.test/a"), Gori::Outbound.cli(scope, false)).should_not be_nil
        end
      end
    end

    it "a value with no boundary byte is untouched by any of this" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("A", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
        head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
        # A horizontal tab is legal in a field-value (RFC 7230 §3.2) and stays legal: the
        # guard is the three bytes `Import::Builder::HEADER_INJECT` names, not "anything odd".
        b.observe(response_result(head, %({"t":"ab\\tcd"})), subject).should eq(["A"])
        with_layer(b) do
          String.new(Gori::Env.expand_bindings("X: $A\r\n\r\n".to_slice)).should eq("X: ab\tcd\r\n\r\n")
        end
      end
    end

    it "reports whether a toggle or a delete actually committed" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        id = b.rules.first.id
        # The store has always answered this; dropping the answer is how the TUI came to
        # toast "extract rule deleted" for a write that rolled back.
        b.toggle(id).should be_true
        b.rules.first.enabled?.should be_false
        b.remove(id).should be_true
        # The Bool means the write COMMITTED (the store's own contract — false is busy /
        # locked / closing), so a DELETE of a row that is already gone is still a commit.
        # `toggle` is false here for a different reason: it reads the rule first, and there is
        # no state to flip, so claiming one changed would be its own false report.
        b.toggle(id).should be_false
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
        # Retained, so re-enabling does not cost a round trip — but read from the table the
        # Bindings pane reads, NOT from `values`, which is what resolves `$NAME` (below).
        b.bound?("SESSION").should be_true
        b.rows.first.value.should eq("abc")
        b.toggle(b.rules.first.id)
        b.values["SESSION"].should eq("abc")
      end
    end

    it "stops resolving a disabled rule's name instead of injecting the stale value" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=abc\r\n\r\n"), subject)
        b.toggle(b.rules.first.id)
        # `declared` already dropped the name; `values` has to agree, or every reader that
        # asks "is this key known?" first — `Env.expand_bindings`, `Rules#substitute` on the
        # proxy path — keeps substituting a token whose writer the operator switched off.
        b.declared.should be_empty
        b.values.has_key?("SESSION").should be_false
        with_layer(b) do
          Gori::Env.expand_bindings("Cookie: sid=$SESSION").should eq("Cookie: sid=$SESSION")
          Gori::Env.display_vars.has_key?("SESSION").should be_false
        end
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

    it "doubles a backslash byte-wise, leaving invalid UTF-8 around it untouched" do
      # `String#gsub("\\", "\\\\")` delegates to the Char overload (1-byte needle) and walks
      # the value with `each_char`, so an invalid byte on either side of the backslash used
      # to come back as three-byte U+FFFD each. Raw fixture, searched byte-wise, matching the
      # bytes a round-7 fixer actually measured on the wire: 0xFF 0xFE 0x5C 0x78.
      bytes = Bytes[0xff_u8, 0xfe_u8, 0x5c_u8, 0x78_u8]
      value = String.new(bytes)
      escaped = Gori::Rules.escape_backrefs(value)
      escaped.to_slice.should eq(Bytes[0xff_u8, 0xfe_u8, 0x5c_u8, 0x5c_u8, 0x78_u8])
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

    it "sends a Position-bound value with invalid UTF-8 through a regex rule byte-exact" do
      # `TokenExtract.position` hands its slice to `String.new` unscrubbed by design (see the
      # comment on it), so a Position binding can carry bytes no `String` literal in this file
      # can spell. Build the fixture at the byte level and drive it through the real path:
      # extract → bind → regex Match&Replace → wire.
      body_bytes = Bytes[0x41_u8, 0xff_u8, 0xfe_u8, 0x5c_u8, 0x78_u8, 0x42_u8] # A <inval> <inval> \ x B
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("TOK", "", Gori::ExtractKind::Position, "", 1, 5)
        b.observe(response_result("HTTP/1.1 200 OK\r\n\r\n", String.new(body_bytes)), subject)
        b.values["TOK"].to_slice.should eq(body_bytes[1...5])
        with_layer(b) do
          rules = Gori::Rules.load(store)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "MARKER", "$TOK", Gori::Store::RuleOp::Replace, Gori::Store::MatchKind::Regex)
          head = "GET /MARKER HTTP/1.1\r\nHost: a\r\n\r\n".to_slice
          got = rules.rewrite_request(head, "a")
          # Byte-exact round trip: `escape_backrefs` doubles the backslash so the SECOND
          # `gsub` (the one splicing `$TOK`'s resolved text into the wire) reads the pair as
          # its own "\\" escape and collapses it back to one — the net wire bytes must equal
          # the ORIGINAL captured value, invalid bytes included, not `ef bf bd` triples.
          exp_buf = IO::Memory.new
          exp_buf.write("GET /".to_slice)
          exp_buf.write(body_bytes[1...5])
          exp_buf.write(" HTTP/1.1\r\nHost: a\r\n\r\n".to_slice)
          got.should eq(exp_buf.to_slice)
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

  # A duplicate `name` is an ignored write, and the id it answers is the caller's only signal.
  # The insert's own `rows_affected` is what makes it 0: SQLite does NOT reset
  # `last_insert_rowid()` when an `INSERT OR IGNORE` is ignored, and neither does the driver's
  # `last_insert_id`, so reading that alone answered the rowid of whatever this long-lived writer
  # connection inserted last — non-zero, so `Bindings#add`'s `== 0` guard never fired and a
  # peer's UNIQUE(name) row came back to the operator as their own rule saved.
  it "answers 0 for a rule whose name collided, not the previous insert's rowid" do
    with_store do |store|
      # The anti-vacuity pin, and it has to be this store handle inside this example:
      # `last_insert_rowid()` is per-connection, so a fresh writer would sit at 0 and the
      # buggy read would be accidentally right.
      first = store.insert_extract_rule("TOKEN", "", Gori::ExtractKind::Cookie, "sid")
      first.should be > 0
      # And it is THIS row's id, not merely some positive number: the id is read off the insert's
      # own `DB::ExecResult`, so a committed write still hands back the row it created.
      store.extract_rules.find { |r| r.name == "TOKEN" }.not_nil!.id.should eq(first)

      store.insert_extract_rule("TOKEN", "", Gori::ExtractKind::Cookie, "other").should eq(0)
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
