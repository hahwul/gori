require "./spec_helper"

# The Decoder chain's `exec:` step (#818) — see `Decoder::EXEC_PREFIX` for why the marker is a
# colon-prefixed keyword rather than the `|` the issue drew.

private def with_hook(body : String, &)
  dir = File.tempname("gori-chain-hook")
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

private def run_chain(spec : String, input : String) : Gori::Decoder::ChainResult
  Gori::Decoder.run(Gori::Decoder.shared_registry, input.to_slice, spec)
end

describe "Decoder exec: step" do
  it "recognises the marker and hands back the argv text" do
    Gori::Decoder.exec_spec("exec:./tool --flag").should eq "./tool --flag"
    Gori::Decoder.exec_spec("EXEC: ./tool").should eq "./tool"
    Gori::Decoder.exec_step?("base64-decode").should be_false
    # A bare marker IS an exec step — an empty one. Falling through to the registry would
    # report `unknown converter "exec:"`, sending the operator after a converter name.
    Gori::Decoder.exec_step?("exec:").should be_true
    Gori::Decoder.exec_spec("exec:").should eq ""
  end

  it "fails a bare `exec:` with `no command`, not with `unknown converter`" do
    res = run_chain("exec:", "hello")
    res.ok?.should be_false
    res.steps[0].state.should eq Gori::Decoder::StepState::Failed
    res.steps[0].error.should eq "no command"
  end

  it "runs the command with the running value on stdin and takes its stdout" do
    with_hook(%q{tr 'a-z' 'A-Z'}) do |hook|
      res = run_chain("exec:#{hook}", "hello")
      res.ok?.should be_true
      String.new(res.output.not_nil!).should eq "HELLO"
    end
  end

  it "composes with built-in converters on both sides" do
    with_hook(%q{tr 'a-z' 'A-Z'}) do |hook|
      res = run_chain("base64-decode > exec:#{hook} > base64-encode", "aGVsbG8=")
      res.ok?.should be_true
      String.new(res.output.not_nil!).should eq "SEVMTE8="
    end
  end

  it "does NOT resolve through the registry - a command spelling a converter name still runs" do
    with_hook(%q{printf 'ran-the-command'}) do |hook|
      # Named `rot13` on disk; a registry lookup would have found the built-in instead.
      dir = File.dirname(hook)
      File.rename(hook, File.join(dir, "rot13"))
      res = run_chain("exec:#{File.join(dir, "rot13")}", "abc")
      String.new(res.output.not_nil!).should eq "ran-the-command"
    end
  end

  it "FAILS the step (and stops the chain) when the command fails, instead of carrying the input" do
    # The Decoder is a workbench, not the proxy data path: silently passing the input forward
    # would hand the operator a value that is not what the chain says it is. See
    # `Decoder.exec_step`.
    with_hook("exit 7") do |hook|
      res = run_chain("exec:#{hook} > base64-encode", "hello")
      res.ok?.should be_false
      res.failed_at.should eq 0
      res.steps[0].state.should eq Gori::Decoder::StepState::Failed
      res.steps[0].error.not_nil!.should contain "exited 7"
      res.steps[1].state.should eq Gori::Decoder::StepState::Skipped
    end
  end

  it "fails the step when the command cannot spawn" do
    res = run_chain("exec:/nonexistent/gori-chain-spec", "hello")
    res.ok?.should be_false
    res.steps[0].error.not_nil!.should contain "/nonexistent/gori-chain-spec"
  end

  it "fails the step when the argv does not tokenize, without running anything" do
    res = run_chain(%q{exec:./tool "oops}, "hello")
    res.ok?.should be_false
    res.steps[0].error.should eq "unterminated double quote"
  end

  it "keeps `|` working as an ordinary separator, so existing chains are unchanged" do
    res = run_chain("base64-encode | url-encode", "a b")
    res.ok?.should be_true
    String.new(res.output.not_nil!).should eq "YSBi"
  end
  it "refuses to run a command through the MCP decode tool, saved chains included" do
    # `decode` is in UNBOUND_SAFE, is never checked against allow_actions, and is documented
    # "pure: no store, no network" — so `exec:` there would be local code execution from a
    # read-only MCP session. The saved-chain half is the sharp edge: a name says nothing.
    reg = Gori::Decoder.build_registry([{"myenc", "base64-encode"}, {"myrun", "exec:./tool"}])
    Gori::Decoder.chain_runs_commands?(reg, "base64-encode > url-encode").should be_false
    Gori::Decoder.chain_runs_commands?(reg, "myenc").should be_false
    Gori::Decoder.chain_runs_commands?(reg, "exec:./tool").should be_true
    Gori::Decoder.chain_runs_commands?(reg, "base64-decode > myrun").should be_true
  end
end
