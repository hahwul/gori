require "../../spec_helper"
require "file_utils"

# `gori run browser` (#1594). The launch is `Browser.start`'s (spec/browser_spec.cr) and the
# capture lookup is the one `gori run shell` uses (spec/cli/run/shell_spec.cr); what is pinned
# here is which browser it picks and that its refusals carry its own name.

private def found(id : String, kind = Gori::Browser::Kind::Chromium) : Gori::Browser::Found
  Gori::Browser::Found.new(id, id.capitalize, kind, "/bin/#{id}")
end

describe "gori run browser" do
  detected = [found("chrome"), found("firefox", Gori::Browser::Kind::Firefox), found("brave")]

  it "picks --browser among the detected ones, else the first" do
    Gori::CLI::Run.browser_choice(detected, "brave", nil).as(Gori::Browser::Found).id.should eq("brave")
    Gori::CLI::Run.browser_choice(detected, nil, nil).as(Gori::Browser::Found).id.should eq("chrome")
    Gori::CLI::Run.browser_choice(detected, "opera", nil).as(String).should contain("detected: chrome, firefox, brave")
    Gori::CLI::Run.browser_choice([] of Gori::Browser::Found, nil, nil).as(String).should contain("no supported browser")
  end

  it "skips Firefox by default when a DevTools port is wanted" do
    firefox_first = [found("firefox", Gori::Browser::Kind::Firefox), found("edge")]
    Gori::CLI::Run.browser_choice(firefox_first, nil, 9222).as(Gori::Browser::Found).id.should eq("edge")
    Gori::CLI::Run.browser_choice([firefox_first[0]], nil, 0).as(String).should contain("Chromium-based")
  end

  it "refuses like gori run shell when nothing captures the project, under its own name" do
    root = File.tempname("gori-run-browser")
    Dir.mkdir_p(root)
    begin
      project = Gori::Project.new("browserproj", File.join(root, "traffic.db"))
      File.write(project.db_path, "")
      msg = Gori::CLI::Run.capture_target(project, nil, nil, "browser").as(String)
      msg.should start_with("gori run browser: no gori is capturing browserproj")
      msg.should contain("--proxy HOST:PORT")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
