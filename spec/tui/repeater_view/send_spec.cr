require "../../spec_helper"

include Gori::Tui

# The Repeater's §…§ send expands env tokens and THEN parses markers, so a project value is
# spliced as a literal there too: it must not open a position or arm a `¦chain`.
describe "RepeaterView marker send with an env value" do
  it "sends a marker+exec value as its own bytes and runs nothing" do
    posix_only!("a #!/bin/sh hook script")
    dir = File.tempname("gori-rv-splice")
    Dir.mkdir_p(dir)
    hook = File.join(dir, "h.sh")
    tally = File.join(dir, "tally")
    File.write(hook, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
    File.chmod(hook, 0o755)
    prev = Gori::Settings.project_env_vars
    value = "§z¦exec:#{hook}§"
    Gori::Settings.project_env_vars = [{"P", value}]
    Gori::Env.bump_highlight_rev
    begin
      view = RepeaterView.new
      view.restore("https://h.test", "GET /?a=§v§&t=$P HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      String.new(view.request_bytes).lines.first.should eq("GET /?a=v&t=#{value} HTTP/1.1")
      File.exists?(tally).should be_false
    ensure
      Gori::Settings.project_env_vars = prev
      Gori::Env.bump_highlight_rev
      FileUtils.rm_rf(dir)
    end
  end

  it "refuses a send whose env value supplies the chain's command step, and runs nothing" do
    posix_only!("a #!/bin/sh hook script")
    dir = File.tempname("gori-rv-envexec")
    Dir.mkdir_p(dir)
    hook = File.join(dir, "h.sh")
    tally = File.join(dir, "tally")
    File.write(hook, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
    File.chmod(hook, 0o755)
    prev = Gori::Settings.project_env_vars
    Gori::Settings.project_env_vars = [{"P", "exec:#{hook}"}, {"H", hook}]
    Gori::Env.bump_highlight_rev
    begin
      view = RepeaterView.new
      view.restore("https://h.test", "POST /?a=x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 3\r\n\r\n§abc¦$P§", false, true)
      expect_raises(Gori::Fuzz::ChainError, Gori::Fuzz::Plan::ENV_COMMAND_REFUSAL) { view.request_bytes }
      # Nor does the explicit `^L` reflection, which may otherwise spend one run.
      view.toggle_auto_content_length
      File.exists?(tally).should be_false
      # A template that names the exec step itself still takes its argument from env.
      named = RepeaterView.new
      named.restore("https://h.test", "GET /?a=§abc¦exec:$H§ HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      String.new(named.request_bytes).lines.first.should eq("GET /?a=abc HTTP/1.1")
      File.read(tally).lines.size.should eq(1)
    ensure
      Gori::Settings.project_env_vars = prev
      Gori::Env.bump_highlight_rev
      FileUtils.rm_rf(dir)
    end
  end
end
