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
end
