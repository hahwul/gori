require "./spec_helper"

# The single outbound chokepoint (issue #354). Everything gori sends that did NOT come from
# a proxied client goes through `Gori::Outbound`, so these specs are the ONE place the
# scope-gate semantics are pinned for all three surfaces (TUI, `gori run`, MCP).

private def with_scope(&)
  path = File.tempname("gori-outbound", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Scope.load(store), store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A Backend that records every request it is asked to send, so a spec can prove a block
# happened BEFORE the socket rather than as a failed connection.
private class RecordingBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin
  getter sent : Int32 = 0

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, Bytes.empty, nil, 1_i64)
  end
end

private ORIGIN = Gori::Fuzz::Origin.new("https", "acme.test", 443)
private REQ    = "GET /s?q=hi HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
private URL    = "https://acme.test/s?q=hi"

describe Gori::Outbound do
  describe "layer 1 — the up-front decision" do
    # The one axis the three surfaces legitimately disagree on, pinned as a table so a
    # future surface has to pick an EXISTING policy rather than invent a fourth.
    #
    #   surface builder                    | no scope rules | out of scope | in scope
    #   -----------------------------------+----------------+--------------+---------
    #   Outbound.agent(scope, false)  MCP  | blocked        | blocked      | allowed
    #   Outbound.cli(scope, false)    CLI  | allowed        | blocked      | allowed
    #   Outbound.interactive(scope)   TUI  | allowed        | allowed      | allowed
    #   Outbound.allowlist(scope)   probe  | blocked        | blocked      | allowed
    it "refuses per the surface's policy when NO scope is configured" do
      with_scope do |scope, _store|
        Gori::Outbound.agent(scope, false).check(URL, "acme.test").blocked?.should be_true
        Gori::Outbound.allowlist(scope).check(URL, "acme.test").blocked?.should be_true
        Gori::Outbound.cli(scope, false).check(URL, "acme.test").blocked?.should be_false
        Gori::Outbound.interactive(scope).check(URL, "acme.test").blocked?.should be_false
        # …and every surface reports the same decision string for the audit trail.
        Gori::Outbound.agent(scope, false).check(URL, "acme.test").decision.should eq("unscoped")
        Gori::Outbound.cli(scope, false).check(URL, "acme.test").decision.should eq("unscoped")
      end
    end

    it "refuses an OUT-OF-SCOPE target on every gated surface" do
      with_scope do |scope, _store|
        scope.add("include", "host", "other.test")
        Gori::Outbound.agent(scope, false).check(URL, "acme.test").blocked?.should be_true
        Gori::Outbound.allowlist(scope).check(URL, "acme.test").blocked?.should be_true
        Gori::Outbound.cli(scope, false).check(URL, "acme.test").blocked?.should be_true
        # The TUI deliberately has no up-front gate — the operator typed this target.
        Gori::Outbound.interactive(scope).check(URL, "acme.test").blocked?.should be_false
        Gori::Outbound.cli(scope, false).check(URL, "acme.test").decision.should eq("out_of_scope")
      end
    end

    it "allows an IN-SCOPE target on every surface and reports the matched rule id" do
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        rule_id = scope.rules.first.id
        [Gori::Outbound.agent(scope, false), Gori::Outbound.cli(scope, false),
         Gori::Outbound.allowlist(scope), Gori::Outbound.interactive(scope)].each do |ob|
          v = ob.check(URL, "acme.test")
          v.blocked?.should be_false
          v.decision.should eq("in_scope")
          v.rule_id.should eq(rule_id)
        end
      end
    end

    it "makes allow_unscoped the ONLY way past a gated refusal, as a NAMED decision" do
      with_scope do |scope, _store|
        scope.add("include", "host", "other.test")
        agent = Gori::Outbound.agent(scope, true)
        agent.check(URL, "acme.test").blocked?.should be_false
        agent.gated?.should be_false
        agent.reason.should eq(Gori::Outbound::Reason::Operator)
        agent.label.should eq("unscoped:operator")
        # The waiver does not rewrite what the scope actually said.
        agent.check(URL, "acme.test").decision.should eq("out_of_scope")

        cli = Gori::Outbound.cli(scope, true)
        cli.check(URL, "acme.test").blocked?.should be_false
        cli.reason.should eq(Gori::Outbound::Reason::Operator)
      end
    end

    it "turns a missing project into an explicit Unscoped(NoProject), not a silent skip" do
      ob = Gori::Outbound.cli(nil, false)
      ob.scope.should be_nil
      ob.gated?.should be_false
      ob.reason.should eq(Gori::Outbound::Reason::NoProject)
      ob.label.should eq("unscoped:no_project")
      # Permissive exactly as the old `scope ? ScopedBackend.new(...) : sender` was — the
      # difference is that the state now has a name and shows up in the audit line.
      ob.check(URL, "acme.test").blocked?.should be_false
      ob.sweep_block("https", "acme.test", "/s?q=hi").should be_nil
    end

    it "fails CLOSED on the allowlist gate when there is no scope to allowlist against" do
      # Probe's per-flow filter: a nil scope must probe NOTHING (the old
      # `!!scope.try(&.matches_url?(...))` behaviour), never everything.
      Gori::Outbound.allowlist(nil).allows?(URL, "acme.test").should be_false
    end

    it "check_request uses the port-less scope URL, so a non-default port stays allowlisted" do
      # FlowRow#url embeds :8443; string/regex includes are written against the port-less
      # form Scope.request_url / QL::URL_EXPR use. Probe Layer 1 must call check_request
      # (or scope_url), not allows?(row.url, …), or every active probe on a non-default
      # port is silently skipped while History still shows the flow in-scope.
      with_scope do |scope, _store|
        scope.add("include", "string", "https://acme.test/")
        ob = Gori::Outbound.allowlist(scope)
        portful = "https://acme.test:8443/admin"
        # Documents the wrong form: a port-bearing URL misses the string include.
        ob.allows?(portful, "acme.test").should be_false
        # The form every other gate builds — and check_request.
        ob.allows?(Gori::Outbound.scope_url("https", "acme.test", "/admin"), "acme.test").should be_true
        ob.check_request("https", "acme.test", "/admin").blocked?.should be_false
        # host rules never cared about port; pin that still holds.
        scope2_path = File.tempname("gori-outbound-host", ".db")
        store2 = Gori::Store.open(scope2_path)
        begin
          s2 = Gori::Scope.load(store2)
          s2.add("include", "host", "acme.test")
          o2 = Gori::Outbound.allowlist(s2)
          o2.check_request("https", "acme.test", "/admin").blocked?.should be_false
          o2.allows?(portful, "acme.test").should be_true # host match ignores URL port
        ensure
          store2.close
          File.delete?(scope2_path)
          File.delete?("#{scope2_path}-wal")
          File.delete?("#{scope2_path}-shm")
        end
      end
    end

    # Regression: Unscoped(NoProject) waives BOTH layers, so it is only ever correct when
    # there genuinely is no project. `gori run repeater send <id>` reads its session out of
    # the most-recently-active project even with no --project flag, and briefly built its
    # decision from the flag alone — which dropped Sandbox containment on the common
    # invocation. `Run.project_outbound` (never the optional_project_ variant) is what those
    # commands must use; this pins the property that makes the distinction matter.
    it "drops BOTH layers under NoProject, so it must never stand in for a real project" do
      no_project = Gori::Outbound.cli(nil, false)
      no_project.check(URL, "acme.test").blocked?.should be_false
      no_project.send_block("https", "acme.test", "/s").should be_nil
      no_project.sweep_block("https", "acme.test", "/s").should be_nil

      # The same command against a real project with Sandbox on must refuse.
      with_scope do |scope, _store|
        scope.enable_sandbox
        real = Gori::Outbound.cli(scope, false)
        real.send_block("https", "acme.test", "/s").should eq(Gori::Outbound::SANDBOX_ERROR)
      end
    end
  end

  describe "layer 2 — the per-send hard gate" do
    it "blocks a SANDBOXed target on every surface, including under allow_unscoped" do
      with_scope do |scope, _store|
        scope.add("include", "host", "other.test")
        scope.enable_sandbox
        [Gori::Outbound.agent(scope, false), Gori::Outbound.agent(scope, true),
         Gori::Outbound.cli(scope, false), Gori::Outbound.cli(scope, true),
         Gori::Outbound.interactive(scope), Gori::Outbound.allowlist(scope)].each do |ob|
          ob.send_block("https", "acme.test", "/s?q=hi").should eq(Gori::Outbound::SANDBOX_ERROR)
          ob.sweep_block("https", "acme.test", "/s?q=hi").should eq(Gori::Outbound::SANDBOX_SWEEP_ERROR)
        end
      end
    end

    it "names WHICH Layer-2 gate refused, preferring the more specific EXCLUDE" do
      # Both reasons used to collapse into one bare "blocked by scope" — the same wording as
      # the Layer-1 abort, so an operator who had just passed --allow-unscoped read those
      # three words back and concluded the flag had done nothing.
      #
      # With the sandbox ON an excluded URL trips BOTH gates (`sandbox_blocks?` is
      # `sandbox && !allowlisted?`, and an exclude un-allowlists). The exclude wins the
      # report: telling someone who already HAS a matching include to "add an include rule"
      # is advice that cannot work, while naming the exclude names the rule to delete.
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "string", "/admin")
        scope.enable_sandbox
        ob = Gori::Outbound.interactive(scope)
        # included host, excluded path → the exclude is the actionable reason
        ob.sweep_block("https", "acme.test", "/admin/panel").should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
        # not in the allowlist at all, and no exclude matches → sandbox
        ob.sweep_block("https", "other.test", "/dashboard").should eq(Gori::Outbound::SANDBOX_SWEEP_ERROR)
        # the two sentences are distinguishable, and each names its own exit
        Gori::Outbound::SANDBOX_SWEEP_ERROR.should_not eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
        Gori::Outbound::SANDBOX_SWEEP_ERROR.should contain("Sandbox off")
        Gori::Outbound::EXCLUDE_SWEEP_ERROR.should contain("--allow-unscoped")
      end
    end

    it "blocks an EXCLUDEd target for a SWEEP but not for one deliberate send" do
      # The distinction the proxy path already draws (Interceptor#sandbox_blocks?): an
      # EXCLUDE is an automation carve-out, so it stops a Fuzzer/Miner/minimize sweep but
      # not a human replaying one Repeater request. Identical on all three surfaces.
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "string", "/admin")
        [Gori::Outbound.agent(scope, false), Gori::Outbound.cli(scope, false),
         Gori::Outbound.interactive(scope)].each do |ob|
          ob.sweep_block("https", "acme.test", "/admin/panel").should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
          ob.send_block("https", "acme.test", "/admin/panel").should be_nil
          ob.sweep_block("https", "acme.test", "/s?q=hi").should be_nil
        end
      end
    end

    it "lets an in-scope target through with the sandbox on" do
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        scope.enable_sandbox
        ob = Gori::Outbound.interactive(scope)
        ob.send_block("https", "acme.test", "/s?q=hi").should be_nil
        ob.sweep_block("https", "acme.test", "/s?q=hi").should be_nil
      end
    end
  end

  describe ".permanent_refusal?" do
    # The retry rule every automated sweep needs: a Layer-2 refusal is settled, so re-asking
    # only burns `retry_pause` and one more charge against the request cap.
    it "is true for the two Layer-2 refusals and for nothing else" do
      Gori::Outbound.permanent_refusal?(Gori::Outbound::SANDBOX_SWEEP_ERROR).should be_true
      Gori::Outbound.permanent_refusal?(Gori::Outbound::EXCLUDE_SWEEP_ERROR).should be_true
      Gori::Outbound.permanent_refusal?(nil).should be_false
      # A real network error still retries as configured.
      Gori::Outbound.permanent_refusal?("Connection refused").should be_false
      # The request cap is a TOOL's constant, deliberately outside this predicate (a core
      # chokepoint must not reach into `fuzz/`), so the callers that treat it as permanent
      # ask about it themselves — see the method comment.
      Gori::Outbound.permanent_refusal?(Gori::Fuzz::CappedBackend::CAP_ERROR).should be_false
      # And the ONE-deliberate-send refusal is not a sweep refusal (`send_block`, not
      # `sweep_block`): a Repeater send has no retry loop to exempt.
      Gori::Outbound.permanent_refusal?(Gori::Outbound::SANDBOX_ERROR).should be_false
    end

    # ONE HOME, executable — the same shape as `spec/layering_spec.cr`, and the same rule
    # AGENTS.md states for `Codec::Http1.request_token_safe?`. This predicate had THREE private
    # copies (`Fuzz::Engine#gate_refused?`, `Miner::Engine#permanent_refusal?`,
    # `Sequencer::Engine#permanent_refusal?`), which is exactly how the Sequencer came to be
    # missing two of the constants its siblings had: the next Layer-2 refusal must be added
    # once, not at three call sites that drift.
    it "matches the Layer-2 refusal strings in exactly one place in src/" do
      root = File.expand_path(File.join(__DIR__, ".."))
      names = /\b(?:SANDBOX_SWEEP_ERROR|EXCLUDE_SWEEP_ERROR)\b/

      # A comment line is one whose `lstrip` starts with `#` — layering_spec's definition,
      # verbatim, and load-bearing here: the Miner and Sequencer comments legitimately name
      # EXCLUDE_SWEEP_ERROR in prose while their code no longer does.
      offenders = [] of String
      Dir.glob(File.join(root, "src", "**", "*.cr")).sort.each do |path|
        rel = Path[path].relative_to(root).to_s
        next if rel == File.join("src", "gori", "outbound.cr")
        File.read_lines(path).each_with_index do |line, i|
          next unless line.matches?(names)
          next if line.lstrip.starts_with?('#')
          offenders << "#{rel}:#{i + 1}: #{line.strip}"
        end
      end
      fail(<<-MSG) unless offenders.empty?
        the Layer-2 refusal rule has ONE home, `Outbound.permanent_refusal?` — no other file \
        may test SANDBOX_SWEEP_ERROR / EXCLUDE_SWEEP_ERROR in code (a comment naming one is \
        fine). Offending lines:
        #{offenders.join("\n")}
        MSG

      # …and the three retry loops must still ASK the shared predicate — in CODE, not merely
      # in a comment: deleting the check outright would also empty the list above.
      {"fuzz", "miner", "sequencer"}.each do |tool|
        calls = File.read_lines(File.join(root, "src", "gori", tool, "engine.cr")).any? do |line|
          line.includes?("Outbound.permanent_refusal?") && !line.lstrip.starts_with?('#')
        end
        calls.should(be_true,
          "src/gori/#{tool}/engine.cr must route its retry loop through Outbound.permanent_refusal?")
      end
    end
  end

  describe "the senders that carry it" do
    # `Fuzz::Sender` is the ONE production backend behind Fuzzer / Miner / Sequencer /
    # Repeater-minimize / Probe-active on all three surfaces, and `Repeater::Sender` the one
    # behind every hand-authored Repeater send. Both take the decision as a CONSTRUCTOR
    # argument, so an ungated one cannot be built — that is what makes the invariant a
    # compile-time property rather than a convention at ~20 call sites.
    it "refuses inside Fuzz::Sender before any socket work" do
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        scope.enable_sandbox
        scope.add("exclude", "host", "acme.test") # un-allowlists it: both Layer-2 gates fire
        sender = Gori::Fuzz::Sender.new(ORIGIN, Gori::Outbound.interactive(scope),
          http2: false, verify: false, timeout: 1.second)
        result = sender.send(REQ)
        # The exclude is the reported reason (see the gate-naming spec above): it is the rule
        # the operator can act on, whereas "add an include" is moot — one is already there.
        result.error.should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
        result.duration_us.should eq(0_i64) # never dialled
        sender.blocked.should eq(1_i64)
      end
    end

    it "gates an INJECTED backend the same way (Probe Active's spec path)" do
      with_scope do |scope, _store|
        scope.add("exclude", "host", "acme.test")
        inner = RecordingBackend.new(ORIGIN)
        gated = Gori::Fuzz::GatedBackend.new(inner, Gori::Outbound.interactive(scope))
        gated.send(REQ).error.should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
        inner.sent.should eq(0)
      end
    end

    it "refuses inside Repeater::Sender, and reports the reason before sending" do
      with_scope do |scope, _store|
        scope.enable_sandbox # no include rules ⇒ the sandbox blocks everything
        sender = Gori::Repeater::Sender.new(Gori::Outbound.interactive(scope),
          scheme: "https", host: "acme.test", port: 443, verify: false)
        sender.refusal(REQ).should eq(Gori::Outbound::SANDBOX_ERROR)
        sender.send(REQ).error.should eq(Gori::Outbound::SANDBOX_ERROR)
        sender.group_refusal([REQ]).should eq(Gori::Outbound::SANDBOX_ERROR)
        # A blocked group refuses as a whole — one connection carries the whole sequence.
        sender.send_group([REQ, REQ]).map(&.error).should eq([Gori::Outbound::SANDBOX_ERROR] * 2)
        sender.send_ws(REQ, [] of Gori::Repeater::WsEngine::OutMsg).error.should eq(Gori::Outbound::SANDBOX_ERROR)
      end
    end
  end

  describe "reload semantics" do
    # ONE semantic for all three surfaces (DESIGN.md §7 / P5): the scope is re-read from its
    # store at most once per RELOAD_INTERVAL, so an operator's mid-run EXCLUDE stops an
    # in-flight sweep whether it started from the TUI, `gori run`, or MCP. Before this,
    # only MCP reloaded; `gori run` snapshotted at start-up and could not be stopped.
    #
    # This is the only spec that pays the wall-clock wait, so it covers all three surfaces
    # in the same window.
    it "honours a mid-run EXCLUDE on every surface once the throttle window elapses" do
      with_scope do |scope, store|
        scope.add("include", "host", "acme.test")
        surfaces = {
          "tui" => Gori::Outbound.interactive(scope),
          "cli" => Gori::Outbound.cli(scope, false),
          "mcp" => Gori::Outbound.agent(scope, false),
        }
        # All three allow the target at start-up.
        surfaces.each { |name, ob| ob.sweep_block("https", "acme.test", "/s").should(be_nil, "#{name} start") }

        # The operator carves the host out mid-run, writing to the SAME db (this is what
        # `gori run project scope add` / the TUI's scope popup do).
        store.add_scope_rule("exclude", "host", "acme.test")

        # Inside the throttle window nothing has reloaded yet…
        surfaces.each { |name, ob| ob.sweep_block("https", "acme.test", "/s").should(be_nil, "#{name} in-window") }

        sleep(Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds)

        # …and past it, every surface stops sending. All three share ONE Scope object here,
        # so assert on separately-loaded scopes too (the CLI/MCP shape) below.
        surfaces.each do |name, ob|
          ob.sweep_block("https", "acme.test", "/s").should(eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR), "#{name} after reload")
        end
      end
    end

    it "reloads a PRIVATE per-job scope too (the MCP / CLI shape)" do
      with_scope do |shared, store|
        # Each surface loads its own Scope from the same store, as fuzz/mine/sequence do.
        ob = Gori::Outbound.agent(Gori::Scope.load(store), false)
        shared.add("include", "host", "acme.test")
        ob.sweep_block("https", "acme.test", "/s").should be_nil

        store.add_scope_rule("exclude", "host", "acme.test")
        sleep(Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds)
        ob.sweep_block("https", "acme.test", "/s").should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
      end
    end

    it "keeps the last-known scope when a reload fails (a closed store must not kill a run)" do
      path = File.tempname("gori-outbound-closed", ".db")
      store = Gori::Store.open(path)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.enable_sandbox
      ob = Gori::Outbound.cli(scope, false)
      store.close
      begin
        sleep(Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds)
        # The reload raises against the closed store and is swallowed; the rules loaded
        # before the close stay in force rather than degrading to "allow everything".
        ob.sweep_block("https", "acme.test", "/s").should be_nil
        ob.sweep_block("https", "other.test", "/s").should eq(Gori::Outbound::SANDBOX_SWEEP_ERROR)
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  describe "#close" do
    it "releases only a store it OWNS" do
      path = File.tempname("gori-outbound-owned", ".db")
      store = Gori::Store.open(path)
      begin
        scope = Gori::Scope.load(store)
        # The TUI/MCP shape: the store belongs to someone longer-lived, so close is a no-op
        # and the scope keeps working afterwards.
        Gori::Outbound.interactive(scope).close
        scope.reload
        # The CLI shape: the Outbound owns the read connection and releases it. Idempotent.
        ob = Gori::Outbound.cli(scope, false, owns_store: store)
        ob.close
        ob.close
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  describe ".scope_url" do
    # A raw request may carry an ABSOLUTE-FORM request line whose host is deliberately not the
    # host being dialled (a Host-header / cache-poisoning / SSRF test). gori sends those bytes
    # verbatim, but the GATE must judge the host it actually connects to — otherwise an
    # anchored include rule for the spoofed host authorises a send to somewhere else.
    it "anchors an absolute-form request line on the DIAL host, not the spoofed one" do
      Gori::Outbound.scope_url("https", "evil.test", "http://acme.test/admin?x=1")
        .should eq("https://evil.test/admin?x=1")
      Gori::Outbound.scope_url("https", "acme.test", "/s?q=hi").should eq("https://acme.test/s?q=hi")
    end

    it "blocks a spoofed absolute-form line that an anchored include would otherwise allow" do
      with_scope do |scope, _store|
        scope.add("include", "regex", "^https?://acme\\.test/")
        scope.enable_sandbox
        ob = Gori::Outbound.interactive(scope)
        # Dialling the allowed origin is fine…
        ob.sweep_block("https", "acme.test", "/x").should be_nil
        # …but dialling evil.test with an acme.test request line must NOT inherit its rule.
        ob.sweep_block("https", "evil.test", "http://acme.test/x").should eq(Gori::Outbound::SANDBOX_SWEEP_ERROR)
        ob.send_block("https", "evil.test", "http://acme.test/x").should eq(Gori::Outbound::SANDBOX_ERROR)
      end
    end

    # The reduction is LEXICAL because `URI.parse` raises on exactly the targets a security
    # tool gets handed. A non-numeric or oversized port used to rescue to nil, read as "no
    # path", and gate `scheme://host/` — so a path EXCLUDE stopped matching the url it was
    # tested against while a host INCLUDE still did, and the carve-out silently opened.
    it "keeps the path when the absolute-form target has a port URI.parse cannot read" do
      Gori::Outbound.scope_url("https", "acme.test", "http://acme.test:abc/admin/purge")
        .should eq("https://acme.test/admin/purge")
      Gori::Outbound.scope_url("https", "acme.test", "http://acme.test:99999999999999999999/admin")
        .should eq("https://acme.test/admin")
    end

    it "still honours a path exclude on a target with an unparseable port" do
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "string", "/admin")
        scope.enable_sandbox
        ob = Gori::Outbound.interactive(scope)
        # The carve-out holds for the well-formed target…
        ob.send_block("https", "acme.test", "http://acme.test/admin/purge")
          .should eq(Gori::Outbound::SANDBOX_ERROR)
        # …and must hold identically when the port is what makes URI.parse raise.
        ob.send_block("https", "acme.test", "http://acme.test:abc/admin/purge")
          .should eq(Gori::Outbound::SANDBOX_ERROR)
      end
    end

    it "reduces a target with no path at all to the root" do
      Gori::Outbound.scope_url("https", "acme.test", "http://acme.test").should eq("https://acme.test/")
    end
  end

  describe ".request_target" do
    it "reads the path from a raw request's first line" do
      Gori::Outbound.request_target("POST /a/b?c=d HTTP/1.1\r\nHost: x\r\n\r\n").should eq("/a/b?c=d")
      Gori::Outbound.request_target("GET /x HTTP/1.1\r\n".to_slice).should eq("/x")
      # A malformed first line degrades to "/" rather than raising on the send path.
      Gori::Outbound.request_target("garbage").should eq("/")
      Gori::Outbound.request_target("".to_slice).should eq("/")
    end

    # A request line with a REPEATED space (or a tab) must still yield the real path, not an
    # empty string — otherwise the scope gate evaluates an empty path and silently satisfies
    # any string/regex include/exclude rule (a full Sandbox bypass with one extra space).
    it "recovers the target from a request line with irregular whitespace" do
      Gori::Outbound.request_target("GET  /admin/x HTTP/1.1\r\nHost: h\r\n\r\n").should eq("/admin/x")
      Gori::Outbound.request_target("GET   /admin/x HTTP/1.1\r\n".to_slice).should eq("/admin/x")
      Gori::Outbound.request_target("POST\t/a/b\tHTTP/1.1\r\n").should eq("/a/b")
    end

    # A LEADING BLANK LINE before the request-line must not blind the gate: reading the empty
    # first line and `split[1]?`-ing it to nil would gate "/" while the REAL target (a later
    # line) goes on the wire — a Sandbox bypass. Scan to the first non-blank line instead.
    it "recovers the target past leading blank line(s) before the request line" do
      Gori::Outbound.request_target("\r\nGET /admin/x HTTP/1.1\r\nHost: h\r\n\r\n").should eq("/admin/x")
      Gori::Outbound.request_target("\nGET /admin/x HTTP/1.1\r\n".to_slice).should eq("/admin/x")
      Gori::Outbound.request_target("\r\n\r\nGET /admin/x HTTP/1.1\r\n").should eq("/admin/x") # doubled leading blank
      Gori::Outbound.request_target("\r\nPOST  /a/b\tHTTP/1.1\r\n").should eq("/a/b")          # blank line + irregular ws
    end

    # CHARACTERISATION. The Bytes overload stopped copying the whole message into a String
    # (a 50 KB POST paid a 50 KB copy per send just to read its first line), so the two
    # overloads no longer share an implementation top to bottom. This is a SCOPE-GATE input:
    # a divergence between them is not a perf regression, it is a gate bypass — the same
    # shape AGENTS.md records as having recurred three times (#390/#394/#397). Every row must
    # answer identically through both, whatever the bytes are.
    it "answers identically through the String and Bytes overloads on hostile input" do
      corpus = [
        "GET /a HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET  /a HTTP/1.1\r\n",            # doubled space
        "GET\t/a\tHTTP/1.1\r\n",           # tabs
        "GET \t /a  HTTP/1.1\r\n",         # mixed whitespace run
        "\r\nGET /a HTTP/1.1\r\n",         # leading blank (CRLF)
        "\nGET /a HTTP/1.1\r\n",           # leading blank (bare LF)
        "\r\n\r\n\r\nGET /a HTTP/1.1\r\n", # several leading blanks
        "   \r\nGET /a HTTP/1.1\r\n",      # whitespace-only first line
        "\rGET /a HTTP/1.1\r\n",           # bare CR line
        "GET /a HTTP/1.1",                 # no trailing newline at all
        "GET",                             # one token, no target
        "GET ",                            # trailing space, empty second token
        " ",                               # a single space: blank throughout
        "",                                # empty
        "\r\n",                            # blank only
        "\n\n\n",                          # blanks only
        "garbage",
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",     # the h2 preface
        "GET http://other.test/p HTTP/1.1\r\n", # absolute-form
        "GET /a?q=1&r=%20 HTTP/1.1\r\n",        # query + percent-encoding
        "GET / a HTTP/1.1\r\n",                 # NBSP inside the target (Unicode whitespace)
        "GET /a HTTP/1.1\r\n",                  # NBSP as the separator
        "GET /café HTTP/1.1\r\n",               # non-ASCII target
      ]
      corpus.each do |raw|
        Gori::Outbound.request_target(raw.to_slice)
          .should eq(Gori::Outbound.request_target(raw)), "diverged on #{raw.inspect}"
      end

      # Invalid UTF-8 cannot round-trip through a String literal, so it gets its own rows.
      [
        Bytes[0x47, 0x45, 0x54, 0x20, 0xff, 0xfe, 0x20, 0x48], # "GET \xff\xfe H"
        Bytes[0xff, 0x0d, 0x0a, 0x47, 0x45, 0x54, 0x20, 0x2f], # invalid first line, then "GET /"
        Bytes[0x00, 0x20, 0x2f, 0x61],                         # NUL as the method
      ].each do |raw|
        Gori::Outbound.request_target(raw)
          .should eq(Gori::Outbound.request_target(String.new(raw))), "diverged on #{raw.inspect}"
      end
    end

    it "keeps the scope gate honest against a doubled-space request line" do
      with_scope do |scope, _store|
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "string", "/admin")
        scope.enable_sandbox
        ob = Gori::Outbound.interactive(scope)
        # A well-formed request to the excluded path is blocked…
        ob.send_block("https", "acme.test", Gori::Outbound.request_target(
          "GET /admin/x HTTP/1.1\r\nHost: acme.test\r\n\r\n")).should eq(Gori::Outbound::SANDBOX_ERROR)
        # …and a doubled space must NOT slip past it.
        ob.send_block("https", "acme.test", Gori::Outbound.request_target(
          "GET  /admin/x HTTP/1.1\r\nHost: acme.test\r\n\r\n")).should eq(Gori::Outbound::SANDBOX_ERROR)
        # …nor a leading blank line before the request-line (the same target-read bypass).
        ob.send_block("https", "acme.test", Gori::Outbound.request_target(
          "\r\nGET /admin/x HTTP/1.1\r\nHost: acme.test\r\n\r\n")).should eq(Gori::Outbound::SANDBOX_ERROR)
      end
    end
  end
end
