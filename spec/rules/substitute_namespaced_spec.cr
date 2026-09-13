require "../spec_helper"

# `Rules#substitute` — a rewrite rule's REPLACEMENT text, under the namespaced grammar.
#
# A replacement is the one field in the product whose only purpose is to inject a value, so its
# grammar is not quite the message grammar and the differences are deliberate:
#
#   * `$$` → one `$` in BOTH syntaxes, both sigils consumed and nothing behind them read. The rule
#     grammar owns that escape (it predates the namespaces), which is what keeps `$$1` a literal
#     `$1` rather than a capture reference.
#   * `$1`..`$9` → `\1`..`\9`, regex replacements only.
#   * a token routes by NAMESPACE: `$ENV.X` comes out of the env-var table and can never be
#     Unbound- or Boundary-refused (an env var is the operator's own bytes, P7), while `$BIND.X`
#     comes out of the binding table and keeps both refusals.
#   * and a BARE `$NAME` whose NAME a table holds is REFUSED rather than shipped as text. That is
#     the one place this grammar is stricter than the message grammar, and the reason is the column:
#     a replacement is a reference by construction, `$$NAME` is its literal, and a bare spelling
#     here is a rule the grammar moved out from under — see `Rules#bare_spelling_at`.

private def with_ns_layer(bindings : Gori::Bindings?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = bindings
  with_env_syntax(Gori::Env::Syntax::Namespaced) do
    yield
  ensure
    Gori::Env.layer = previous
  end
end

private def with_env_vars(vars : Array({String, String}), &)
  prev = Gori::Settings.project_env_vars
  Gori::Settings.project_env_vars = vars
  Gori::Env.bump_highlight_rev
  begin
    yield
  ensure
    Gori::Settings.project_env_vars = prev
    Gori::Env.bump_highlight_rev
  end
end

private def response_body_result(body : String) : Gori::Repeater::Result
  bytes = "HTTP/1.1 200 OK\r\n\r\n".to_slice
  parsed = Gori::Proxy::Codec::Http1.parse_response_head(bytes)
  Gori::Repeater::Result.new(bytes, body.to_slice, parsed, 1_i64, nil)
end

private def ns_subject(host : String = "acme.test") : Gori::InterceptFilter::Subject
  Gori::InterceptFilter::Subject.new(method: "POST", host: host, target: "/login",
    scheme: "https", status: 200)
end

describe "Rules#substitute — namespaced" do
  it "resolves $ENV.X and $BIND.X out of their own tables" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
      b.observe(response_body_result(%({"t":"BOUND"})), ns_subject)
      with_ns_layer(b) do
        with_env_vars([{"TOKEN", "ENVVAL"}, {"SESSION", "ENVSESSION"}]) do
          rules = Gori::Rules.new(store, store.match_rules)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-A",
            "e=$ENV.TOKEN b=$BIND.SESSION e2=$ENV.SESSION", Gori::Store::RuleOp::SetHeader,
            Gori::Store::MatchKind::Literal, "inject", "", "")
          out = rules.transform_message("GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n",
            Gori::Store::RuleTarget::Request, "acme.test")
          # No cross-table resolution: `$ENV.SESSION` is the env var, not the bound value.
          out.should contain("X-A: e=ENVVAL b=BOUND e2=ENVSESSION")
        end
      end
    end
  end

  it "keeps $$ → one $ and $1 → \\1 in the namespaced grammar too" do
    with_store do |store|
      with_ns_layer(nil) do
        with_env_vars([{"A", "V"}]) do
          rules = Gori::Rules.new(store, store.match_rules)
          # A regex Replace: `$1` is a capture ref, `$$1` is the literal `$1`, `$$` is one `$`,
          # and `$ENV.A` still resolves beside them.
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body,
            "(\\w+)=(\\w+)", "$2=$1 lit=$$1 d=$$ v=$ENV.A", Gori::Store::RuleOp::Replace,
            Gori::Store::MatchKind::Regex, "swap", "", "")
          out = rules.transform_message("POST / HTTP/1.1\r\n\r\nk=v",
            Gori::Store::RuleTarget::Request, "acme.test")
          out.should end_with("v=k lit=$1 d=$ v=V")
        end
      end
    end
  end

  it "leaves an app-grammar $1 / $ne / $unknown in a replacement alone" do
    with_store do |store|
      with_ns_layer(nil) do
        with_env_vars([{"id", "ENVVAL"}]) do
          rules = Gori::Rules.new(store, store.match_rules)
          # NONE of these names is in a table, so none of them is a reference in any grammar — which
          # is the whole reason namespaces exist.
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body,
            "PAYLOAD", %({"q":"query($userId){x}","f":{"$ne":1},"r":"$ref"}),
            Gori::Store::RuleOp::Replace, Gori::Store::MatchKind::Literal, "graphql", "", "")
          out = rules.transform_message("POST / HTTP/1.1\r\n\r\nPAYLOAD",
            Gori::Store::RuleTarget::Request, "acme.test")
          out.should end_with(%({"q":"query($userId){x}","f":{"$ne":1},"r":"$ref"}))
        end
      end
    end
  end

  # A bare `$NAME` whose NAME one of the tables holds is a STALE SPELLING, not a payload, and the
  # rule does not apply.
  #
  # A replacement is a reference by construction — it is the one column whose purpose is to inject a
  # value — and `$$NAME` is how a literal `$NAME` is written there. So there are only two ways to
  # get a bare one under this grammar, and neither is "the operator meant it": a GLOBAL rule naming
  # a project var or an extract rule (the load-time re-spelling cannot see those names, and the
  # project-open reconcile deliberately only NAMES them), or a rule that was inert until someone
  # added a var with that name. Shipping the literal put eight known-wrong characters into an
  # `Authorization` header on every proxied request, silently, for as long as the rule was enabled.
  it "refuses a bare $NAME that names a var, and names the re-spelling" do
    with_store do |store|
      with_ns_layer(nil) do
        with_env_vars([{"id", "ENVVAL"}]) do
          rules = Gori::Rules.new(store, store.match_rules)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-A",
            "v=$id", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
            "stale", "", "")
          out = rules.transform_message("GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n",
            Gori::Store::RuleTarget::Request, "acme.test")
          # Not applied — and in particular NOT applied with the literal bytes `v=$id`.
          out.should_not contain("X-A")
          ev = store.events_after(0, 50).find { |e| e.kind == "bare_spelling" }.not_nil!
          ev.level.should eq("warn")
          ev.message.should contain(%(rewrite rule "stale" not applied))
          ev.message.should contain("$id is the bare spelling")
          ev.message.should contain("write $ENV.id to inject the value")
          ev.message.should contain("$$id to inject the text")
        end
      end
    end
  end

  it "names the BIND spelling when the name is a declared binding" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      with_ns_layer(b) do
        rules = Gori::Rules.new(store, store.match_rules)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
          "$SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
          "stale-bind", "", "")
        rules.transform_message("GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n",
          Gori::Store::RuleTarget::Request, "acme.test").should_not contain("X-Auth")
        ev = store.events_after(0, 50).find { |e| e.kind == "bare_spelling" }.not_nil!
        ev.message.should contain("write $BIND.SESSION to inject the value")
      end
    end
  end

  # `$$NAME` is the escape the refusal points at, so it must keep working — and it must not be read
  # as a stale spelling on the way through. `$1` is a capture reference and never a name.
  it "keeps $$NAME a literal and $1 a backref, with no refusal" do
    with_store do |store|
      with_ns_layer(nil) do
        with_env_vars([{"id", "ENVVAL"}]) do
          rules = Gori::Rules.new(store, store.match_rules)
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body,
            "(\\w+)", "lit=$$id ref=$1 v=$ENV.id", Gori::Store::RuleOp::Replace,
            Gori::Store::MatchKind::Regex, "escaped", "", "")
          out = rules.transform_message("POST / HTTP/1.1\r\n\r\nk",
            Gori::Store::RuleTarget::Request, "acme.test")
          out.should end_with("lit=$id ref=k v=ENVVAL")
          store.events_after(0, 50).find { |e| e.kind == "bare_spelling" }.should be_nil
        end
      end
    end
  end

  # BARE mode is the contract the whole existing suite pins, and nothing here may reach it: a bare
  # install resolves `$id` out of the merged table, which is the behaviour that shipped.
  it "does not refuse a bare spelling under the BARE grammar" do
    with_store do |store|
      with_env_vars([{"id", "ENVVAL"}]) do
        rules = Gori::Rules.new(store, store.match_rules)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-A",
          "v=$id", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
          "bare", "", "")
        rules.transform_message("GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n",
          Gori::Store::RuleTarget::Request, "acme.test").should contain("X-A: v=ENVVAL")
        store.events_after(0, 50).find { |e| e.kind == "bare_spelling" }.should be_nil
      end
    end
  end

  it "refuses a declared-but-unbound $BIND.X, and spells it in the event" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      with_ns_layer(b) do
        rules = Gori::Rules.new(store, store.match_rules)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
          "$BIND.SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
          "inject", "", "")
        out = rules.transform_message("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n",
          Gori::Store::RuleTarget::Request, "acme.test")
        out.should_not contain("X-Auth")
        ev = store.events_after(0, 50).find { |e| e.kind == "unbound" }.not_nil!
        ev.message.should eq(%(rewrite rule "inject" not applied: $BIND.SESSION is not bound yet))
      end
    end
  end

  # An `$ENV.X` naming the same key CANNOT be refused: an env var is the operator's own bytes and
  # is byte-exact by policy, so the rule applies and the unresolved name stays literal.
  it "never refuses an $ENV.X, even when an extract rule declares that name" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      with_ns_layer(b) do
        rules = Gori::Rules.new(store, store.match_rules)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Auth",
          "$ENV.SESSION", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
          "inject", "", "")
        out = rules.transform_message("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n",
          Gori::Store::RuleTarget::Request, "acme.test")
        out.should contain("X-Auth: $ENV.SESSION") # literal, whole
        store.events_after(0, 50).any? { |e| e.kind == "unbound" }.should be_false
      end
    end
  end

  # A binding value is server-controlled: a CR/LF in it would forge a header line. Refused in a
  # HEAD only, and only for the BIND namespace.
  it "refuses a boundary-forging $BIND.X in a head and allows the same value in a body" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("T", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
      b.observe(response_body_result(%({"t":"abc\\r\\nX-Admin: true"})),
        ns_subject)
      with_ns_layer(b) do
        rules = Gori::Rules.new(store, store.match_rules)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-A",
          "$BIND.T", Gori::Store::RuleOp::SetHeader, Gori::Store::MatchKind::Literal,
          "head", "", "")
        head_out = rules.transform_message("GET /a HTTP/1.1\r\nHost: acme.test\r\n\r\n",
          Gori::Store::RuleTarget::Request, "acme.test")
        head_out.should_not contain("X-Admin")
        store.events_after(0, 50).any? { |e| e.kind == "boundary_refused" }.should be_true
      end
    end
  end

  it "accepts a namespaced token inside a pipe rule's argv" do
    with_ns_layer(nil) do
      with_env_vars([{"A", "one two"}]) do
        # A pipe rule resolves each ARGV ELEMENT separately, so the token must survive the argv
        # parse intact — running the command is `rules/pipe_spec`'s job.
        Gori::Rules.pipe_argv_error(Gori::Store::RuleOp::Pipe, %(/bin/cat "$ENV.A")).should be_nil
      end
    end
  end
end
