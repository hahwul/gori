require "./spec_helper"

private alias F = Gori::Fuzz

# An EVIDENCE replay unescapes nothing, under the namespaced grammar too.
#
# `Escape::Preserve` is a BARE-MODE KNOB. Under the namespaced grammar `Env.unescape_set` ignores
# the enum entirely and hands the call its own `resolve` set — "a pass owns its escapes" — so an
# evidence branch that expanded a NARROWED var table (`RepeaterView#expanded_text_to_bytes`,
# `Fuzz::Plan.build`) was also consuming `$$ENV.X` and replaying `$ENV.X` to the origin. A `$$` in
# captured bytes is two bytes the origin sent: there is nothing there for the operator to have
# escaped, so the pass has to be told in the only vocabulary that says it — `unescape: Owns::None`.
#
# The DRAFT default must not move with it: `expand_wire` still consumes `$$ENV.X` by default,
# because the binding pass behind it never will (it owns `$$BIND.X` and nothing else).
private CAPTURED_BODY = %({"a":"$$ENV.PATH","b":"$$","c":"$$BIND.T"})

private def with_ns_vars(&)
  prev_prefix = Gori::Settings.env_prefix
  prev_global = Gori::Settings.env_vars
  prev_project = Gori::Settings.project_env_vars
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [{"PATH", "/etc/passwd"}, {"T", "envT"}]
  Gori::Settings.project_env_vars = [] of {String, String}
  with_env_syntax(Gori::Env::Syntax::Namespaced) do
    yield
  ensure
    Gori::Settings.env_prefix = prev_prefix
    Gori::Settings.env_vars = prev_global
    Gori::Settings.project_env_vars = prev_project
    Gori::Env.bump_highlight_rev
  end
end

describe "namespaced escapes on an EVIDENCE path" do
  it "leaves every captured escape byte-exact when the caller says Owns::None" do
    with_ns_vars do
      vars = {"PATH" => "/etc/passwd", "T" => "envT"}
      out = String.new(Gori::Env.expand_wire(CAPTURED_BODY, vars,
        unescape: Gori::Env::Owns::None))
      out.should eq(CAPTURED_BODY)
    end
  end

  it "still consumes $$ENV.X on the DRAFT default, where the binding pass never would" do
    with_ns_vars do
      # The default is the plan-build pass, and it is the ONLY pass that will ever see `$$ENV.X`:
      # `expand_bindings` owns `$$BIND.X` alone. Changing this default would ship `$$ENV.PATH`.
      out = String.new(Gori::Env.expand_wire(CAPTURED_BODY))
      out.should eq(%({"a":"$ENV.PATH","b":"$$","c":"$$BIND.T"}))
    end
  end

  # The seam above, through the builder that used to get it wrong: an evidence run with a NARROWED
  # var table (the TUI Fuzzer template editor's `@evidence_env_names` path) is the one evidence
  # caller that expands at all, so it is the one that could consume an escape.
  it "replays a captured body byte-exact through Fuzz::Plan.build" do
    with_ns_vars do
      template = "POST /p?q=§v§ HTTP/1.1\r\nHost: t.test\r\n" \
                 "Content-Length: #{CAPTURED_BODY.bytesize}\r\n\r\n#{CAPTURED_BODY}"
      plan = F::Plan.build(F::PlanOptions.new(template, target: "http://t.test",
        sources: [F::InlineList.new(["1"])] of F::PayloadSource,
        config: F::Config.new(keep_bodies: :none), verify: false,
        evidence: true, env_vars: {"PATH" => "/etc/passwd", "T" => "envT"}), ungated_outbound)
      jobs = [] of F::Job
      plan.generator.each { |j| jobs << j }
      wire = String.new(jobs[0].bytes)
      wire.should end_with("\r\n\r\n#{CAPTURED_BODY}")
      # …and the narrowing still WORKS: the operator's own token in the head resolves.
      wire.should start_with("POST /p?q=1 HTTP/1.1\r\n")
    end
  end

  # A DRAFT run through the same builder is unchanged: the escape is consumed at plan-build,
  # because nothing behind it will.
  it "consumes the env escape on a draft run through the same builder" do
    with_ns_vars do
      template = "POST /p?q=§v§ HTTP/1.1\r\nHost: t.test\r\n" \
                 "Content-Length: #{CAPTURED_BODY.bytesize}\r\n\r\n#{CAPTURED_BODY}"
      plan = F::Plan.build(F::PlanOptions.new(template, target: "http://t.test",
        sources: [F::InlineList.new(["1"])] of F::PayloadSource,
        config: F::Config.new(keep_bodies: :none), verify: false), ungated_outbound)
      jobs = [] of F::Job
      plan.generator.each { |j| jobs << j }
      String.new(jobs[0].bytes).should contain(%({"a":"$ENV.PATH","b":"$$","c":"$$BIND.T"}))
    end
  end
end
