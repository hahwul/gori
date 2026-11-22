require "../spec_helper"

private alias F = Gori::Fuzz

# A project env value spliced into a §…§ template is DATA: it must reach the wire as exactly its
# bytes and never become a position or a `¦chain`. Spliced raw, `§z¦exec:CMD§` in a value armed a
# command that the exec gate had judged absent (the value changed after the template was checked),
# and `ab§cd§ef` added a position the operator never marked.

private def with_project_env(vars : Array({String, String}), &)
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

private def with_counting_hook(&)
  posix_only!("a #!/bin/sh hook script")
  dir = File.tempname("gori-env-splice-hook")
  Dir.mkdir_p(dir)
  path = File.join(dir, "h.sh")
  tally = File.join(dir, "tally")
  File.write(path, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
  File.chmod(path, 0o755)
  begin
    yield({path, -> { File.exists?(tally) ? File.read(tally).lines.size : 0 }})
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def splice_options(template : String, values = ["x"], commands_allowed = true) : F::PlanOptions
  F::PlanOptions.new(template, target: "http://t.test",
    sources: values.map { |v| F::InlineList.new([v]).as(F::PayloadSource) },
    config: F::Config.new(keep_bodies: :none), verify: false, commands_allowed: commands_allowed)
end

private def jobs_of(plan : F::Plan) : Array(String)
  out = [] of String
  plan.generator.each { |j| out << String.new(j.bytes) }
  out
end

describe "an env value spliced into a fuzz template" do
  it "never becomes a ¦chain, so a value carrying exec: runs nothing and goes out as its bytes" do
    with_counting_hook do |hook, runs|
      value = "§z¦exec:#{hook}§"
      with_project_env([{"P", value}]) do
        plan = F::Plan.build(splice_options("GET /q?a=§v§&t=$P HTTP/1.1\r\nHost: t.test\r\n\r\n"), ungated_outbound)
        plan.position_count.should eq(1)
        plan.template.runs_commands?(Gori::Decoder.shared_registry).should be_false
        # The agent-time gate and the operator's run now judge the same template.
        F::Plan.build(splice_options("GET /q?a=§v§&t=$P HTTP/1.1\r\nHost: t.test\r\n\r\n", commands_allowed: false), ungated_outbound)
        reqs = jobs_of(plan)
        reqs.size.should eq(1)
        reqs[0].lines.first.should eq("GET /q?a=x&t=#{value} HTTP/1.1")
        runs.call.should eq(0)
      end
    end
  end

  it "adds no position when the value carries a marker pair" do
    with_project_env([{"TOK", "ab§cd§ef"}]) do
      plan = F::Plan.build(splice_options("GET /q?a=§v§ HTTP/1.1\r\nHost: t.test\r\nX-Tok: $TOK\r\n\r\n", ["1"]), ungated_outbound)
      plan.position_count.should eq(1)
      jobs_of(plan).map { |r| r.lines[2] }.should eq(["X-Tok: ab§cd§ef"])
    end
  end

  it "stays the position's default, not its chain, inside a marker" do
    with_project_env([{"D", "a¦base64§b"}]) do
      plan = F::Plan.build(splice_options("GET /q?a=§$D§&b=§w§ HTTP/1.1\r\nHost: t.test\r\n\r\n", ["1"]), ungated_outbound)
      plan.position_count.should eq(2)
      plan.template.positions[0].default.should eq("a¦base64§b")
      plan.template.positions[0].chain.should eq("")
      # Sniper: position 0 swept first, with position 1 at its default; then the other way round.
      jobs_of(plan).map(&.lines.first).should eq([
        "GET /q?a=1&b=w HTTP/1.1",
        "GET /q?a=a¦base64§b&b=1 HTTP/1.1",
      ])
    end
  end

  it "is spliced as a literal into a typed WebSocket frame too" do
    with_project_env([{"F", "§q§"}]) do
      options = splice_options("GET /ws HTTP/1.1\r\nHost: t.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
      options.ws_messages = [F::WsMessageSource.new(Gori::Proxy::WS::OP_TEXT.to_i, "{\"a\":\"§v§\",\"b\":\"$F\"}")]
      plan = F::Plan.build(options, ungated_outbound)
      plan.position_count.should eq(1)
      plan.ws_script.not_nil!.frames[0].template.segments.join.should contain("\"b\":\"§q§\"")
    end
  end

  it "keeps a template's own $KEY-free markers and env-free text byte-identical" do
    with_project_env([{"P", "plain"}]) do
      plan = F::Plan.build(splice_options("GET /q?a=§v§&t=$P&l=§§ HTTP/1.1\r\nHost: t.test\r\n\r\n"), ungated_outbound)
      plan.position_count.should eq(1)
      jobs_of(plan)[0].lines.first.should eq("GET /q?a=x&t=plain&l=§ HTTP/1.1")
    end
  end
end
