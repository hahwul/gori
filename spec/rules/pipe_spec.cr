require "../spec_helper"

# The Rewriter `pipe` op (#818): a rule whose replacement is COMPUTED by an external command.
#
# The examples that matter here are the failure ones. P6 says the proxy data path never stalls,
# so every way a hook can go wrong — a command that will not parse, will not spawn, exits
# non-zero, times out, or floods stdout — has to leave the bytes EXACTLY as they arrived and say
# so in the event feed. A green "it transformed the body" example proves almost nothing next to
# those; the whole risk of this feature is what happens when the operator's script misbehaves.

private def with_store(&)
  path = File.tempname("gori-pipe", ".db")
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

private def with_hook(body : String, &)
  dir = File.tempname("gori-pipe-hook")
  Dir.mkdir_p(dir)
  path = File.join(dir, "hook.sh")
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def pipe_rule(command : String, *, pattern = "TOKEN", kind = Gori::Store::MatchKind::Literal,
                      part = Gori::Store::RulePart::Body,
                      target = Gori::Store::RuleTarget::Request,
                      id = 1_i64) : Gori::Store::MatchRule
  Gori::Store::MatchRule.new(id, true, target, part, pattern, command,
    Gori::Store::RuleOp::Pipe, kind, "signer", "")
end

private def hook_events(store) : Array(String)
  store.events_after(0_i64, 200).select { |e| e.kind == "hook_failed" }.map(&.message)
end

describe "Rewriter pipe op" do
  it "replaces the matched region with the command's stdout" do
    with_store do |store|
      with_hook(%q{tr 'a-z' 'A-Z'}) do |hook|
        rules = Gori::Rules.new(store, [pipe_rule(hook, pattern: "secret")])
        got = rules.rewrite_request_body("keep secret keep".to_slice, "acme.test")
        String.new(got).should eq "keep SECRET keep"
      end
    end
  end

  it "feeds only the MATCHED region, so a regex rule can recompute one field" do
    with_store do |store|
      with_hook(%q{printf 'signed-%s' "$(cat)"}) do |hook|
        rules = Gori::Rules.new(store, [pipe_rule(hook, pattern: "tok=([a-z]+)",
          kind: Gori::Store::MatchKind::Regex)])
        got = rules.rewrite_request_body("a&tok=abc&b".to_slice, "acme.test")
        String.new(got).should eq "a&signed-tok=abc&b"
      end
    end
  end

  it "hands the hook its context in the environment" do
    with_store do |store|
      with_hook(%q{printf '%s|%s|%s|%s' "$GORI_HOOK" "$GORI_TARGET" "$GORI_PART" "$GORI_HOST"}) do |hook|
        rules = Gori::Rules.new(store, [pipe_rule(hook, pattern: "X")])
        got = rules.rewrite_request_body("X".to_slice, "acme.test")
        String.new(got).should eq "rewriter|request|body|acme.test"
      end
    end
  end

  it "passes the original bytes through when the hook EXITS NON-ZERO, and says so" do
    with_store do |store|
      with_hook("echo 'nope' >&2; exit 4") do |hook|
        rules = Gori::Rules.new(store, [pipe_rule(hook, pattern: "TOKEN")])
        body = "a TOKEN b".to_slice
        String.new(rules.rewrite_request_body(body, "acme.test")).should eq "a TOKEN b"
        msgs = hook_events(store)
        msgs.size.should eq 1
        msgs.first.should contain "exited 4"
        msgs.first.should contain "passed through unchanged"
      end
    end
  end

  it "passes the original bytes through when the hook CANNOT SPAWN, and says so" do
    with_store do |store|
      rules = Gori::Rules.new(store, [pipe_rule("/nonexistent/gori-pipe-spec")])
      String.new(rules.rewrite_request_body("a TOKEN b".to_slice, "acme.test")).should eq "a TOKEN b"
      hook_events(store).first.should contain "/nonexistent/gori-pipe-spec"
    end
  end

  it "passes the original bytes through when the hook TIMES OUT, without holding the message" do
    with_store do |store|
      prev = Gori::Settings.hook_timeout_secs
      begin
        Gori::Settings.hook_timeout_secs = 1
        rules = Gori::Rules.new(store, [pipe_rule("/bin/sleep 30")])
        started = Time.instant
        got = rules.rewrite_request_body("a TOKEN b".to_slice, "acme.test")
        elapsed = Time.instant - started
        String.new(got).should eq "a TOKEN b"
        # The P6 assertion: the rule cost the message its budget and the graces, not 30 seconds.
        elapsed.should be < 10.seconds
        hook_events(store).first.should contain "timed out"
      ensure
        Gori::Settings.hook_timeout_secs = prev
      end
    end
  end

  it "refuses an unparseable command at apply time instead of running something else" do
    with_store do |store|
      rules = Gori::Rules.new(store, [pipe_rule(%q{./sign "unterminated})])
      String.new(rules.rewrite_request_body("a TOKEN b".to_slice, "acme.test")).should eq "a TOKEN b"
      hook_events(store).first.should contain "does not parse"
    end
  end

  it "spends ONE budget across every match in a message, not one per match" do
    with_store do |store|
      prev = Gori::Settings.hook_timeout_secs
      begin
        Gori::Settings.hook_timeout_secs = 1
        # Twenty matches, each of which would sleep out the whole budget on its own. Without a
        # shared budget this message would be held for twenty timeouts.
        rules = Gori::Rules.new(store, [pipe_rule("/bin/sleep 30", pattern: "X")])
        body = ("X" * 20).to_slice
        started = Time.instant
        got = rules.rewrite_request_body(body, "acme.test")
        elapsed = Time.instant - started
        String.new(got).should eq "X" * 20
        elapsed.should be < 15.seconds
      ensure
        Gori::Settings.hook_timeout_secs = prev
      end
    end
  end

  it "is not a header op, and keeps whatever part it was written with" do
    # `RuleOp#header?` used to be a negation ("not replace and not short_circuit"), which would
    # have swept Pipe up the moment it was added and forced every pipe rule onto the head.
    Gori::Store::RuleOp::Pipe.header?.should be_false
    Gori::Store::RuleOp::Pipe.rewrite?.should be_true
    Gori::Store::RuleOp::Pipe.executes?.should be_true
    Gori::Rules.normalize_shape(Gori::Store::RuleOp::Pipe,
      Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body)
      .should eq({Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body})
  end

  it "validates the command through one shared validator" do
    Gori::Rules.pipe_argv_error(Gori::Store::RuleOp::Pipe, "./sign --key k").should be_nil
    Gori::Rules.pipe_argv_error(Gori::Store::RuleOp::Pipe, "").should_not be_nil
    Gori::Rules.pipe_argv_error(Gori::Store::RuleOp::Pipe, %q{./sign "oops}).should_not be_nil
    # Silent for every other op, so the surfaces can call it unconditionally.
    Gori::Rules.pipe_argv_error(Gori::Store::RuleOp::Replace, %q{"oops}).should be_nil
  end

  it "counts the flows a pipe rule would RUN ON rather than spawning once per flow" do
    # A preview must not fork the operator's command 500 times on a keystroke — see
    # `Rules#pattern_matches?`. `/nonexistent/...` proves it: if the preview ran the command the
    # match count would be zero, because the transform would fail and the bytes would be equal.
    with_store do |store|
      3.times do
        req = Gori::Store::CapturedRequest.new(
          created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
          method: "POST", target: "/", http_version: "HTTP/1.1",
          head: "POST / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
          body: "a TOKEN b".to_slice, source: Gori::FlowSource::Kind::Proxy)
        store.insert_flow(req)
      end
      pv = Gori::Rules.new(store, [] of Gori::Store::MatchRule)
        .preview(pipe_rule("/nonexistent/gori-pipe-spec"))
      pv.matched.should eq 3
    end
  end
  it "expands $KEY INSIDE an argv element, so a captured value can never add an argument" do
    # The injection this ordering exists to prevent: resolve-then-tokenize would let an origin
    # that mints `TOKEN` as `x --config /tmp/evil.yml` hand the operator's own script a flag
    # they never wrote. There is no shell here, so quoting could not have saved it — the split
    # has to not happen at all.
    with_store do |store|
      begin
        Gori::Env.save_project(store, [{"TOKEN", "x --config /tmp/evil.yml"}])
        with_hook(%q{printf '%s|' "$@"}) do |hook|
          rules = Gori::Rules.new(store, [pipe_rule("#{hook} --key $TOKEN", pattern: "X")])
          got = rules.rewrite_request_body("X".to_slice, "acme.test")
          # THREE arguments, not five: the value stayed one element.
          String.new(got).should eq "--key|x --config /tmp/evil.yml|"
        end
      ensure
        Gori::Env.save_project(store, [] of {String, String})
      end
    end
  end

  it "does not splice an EMPTY replacement when the hook's stdout could not be collected" do
    # `ProcessHook#ok?` must be false when a pump is abandoned. If a lost pump read as an empty
    # success the matched bytes would be DELETED on the live wire, silently.
    lost = Gori::ProcessHook::Result.new("hook", 0, Bytes.empty, "", false, false, nil, true)
    lost.ok?.should be_false
    lost.failure.not_nil!.should contain "held open"
    Gori::ProcessHook::Result.new("hook", 0, Bytes.empty, "", false, false, nil).ok?.should be_true
  end

  it "de-duplicates a notice on the failure CLASS, not on the child's stderr" do
    # A hook that prints a timestamp before failing must not write one SQLite row per proxied
    # message on the data path.
    with_store do |store|
      with_hook("echo \"attempt $$-$(date +%N)\" >&2; exit 9") do |hook|
        rules = Gori::Rules.new(store, [pipe_rule(hook, pattern: "TOKEN")])
        5.times { rules.rewrite_request_body("a TOKEN b".to_slice, "acme.test") }
        hook_events(store).size.should eq 1
      end
    end
  end

  it "spends ONE budget across every pipe RULE in a rewrite, not one each" do
    # Per-rule deadlines multiplied: three rules at the 60s ceiling would hold one head for
    # three minutes, which is not a bound at all.
    with_store do |store|
      prev = Gori::Settings.hook_timeout_secs
      begin
        Gori::Settings.hook_timeout_secs = 1
        rules = Gori::Rules.new(store, [
          pipe_rule("/bin/sleep 30", pattern: "A", id: 1_i64),
          pipe_rule("/bin/sleep 30", pattern: "B", id: 2_i64),
          pipe_rule("/bin/sleep 30", pattern: "C", id: 3_i64),
        ])
        started = Time.instant
        got = rules.rewrite_request_body("ABC".to_slice, "acme.test")
        String.new(got).should eq "ABC"
        (Time.instant - started).should be < 12.seconds
      ensure
        Gori::Settings.hook_timeout_secs = prev
      end
    end
  end

  it "does not claim a ws-only pipe rule was skipped in an HTTP preview" do
    with_store do |store|
      ws = pipe_rule("/bin/cat", pattern: "X", part: Gori::Store::RulePart::Ws)
      rules = Gori::Rules.new(store, [ws])
      rules.pipes_for?(Gori::Store::RuleTarget::Request, "acme.test").should be_false
      body = pipe_rule("/bin/cat", pattern: "X")
      Gori::Rules.new(store, [body])
        .pipes_for?(Gori::Store::RuleTarget::Request, "acme.test").should be_true
    end
  end
end
