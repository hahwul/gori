require "../../spec_helper"
require "file_utils"

# `gori run shell` (#1238). The exec itself replaces the process, so what is pinned here is
# everything before it: which gori the shell points at, when it refuses, and the flag
# combinations it will not guess about. The environment is `ShellEnv`'s (spec/shell_env_spec.cr).

private def with_capture_project(&)
  root = File.tempname("gori-run-shell")
  Dir.mkdir_p(root)
  begin
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
    project = Gori::Project.new("shellproj", File.join(root, "traffic.db"))
    File.write(project.db_path, "")
    yield project, ca.ca_cert_path, root
  ensure
    FileUtils.rm_rf(root)
  end
end

# Hold the project's capture lock the way a live gori does, for the block.
private def capturing(project : Gori::Project, &)
  lock = Gori::CaptureLock.try_at(project.capture_lock_path).not_nil!
  begin
    yield
  ensure
    lock.close
  end
end

private def target!(result) : Gori::CLI::Run::ShellTarget
  result.as(Gori::CLI::Run::ShellTarget)
end

describe "gori run shell — flags" do
  it "wants the command after --, so its own flags are never read as gori's" do
    Gori::CLI::Run.shell_usage_error(["curl"], [] of String, false, nil, nil, nil, nil).not_nil!
      .should contain("gori run shell -- curl")
    Gori::CLI::Run.shell_usage_error([] of String, ["curl", "-v"], false, nil, nil, nil, nil).should be_nil
  end

  it "refuses --print with a command, --shell without --print, and an unknown syntax" do
    Gori::CLI::Run.shell_usage_error([] of String, ["curl"], true, nil, nil, nil, nil).not_nil!.should contain("--print")
    Gori::CLI::Run.shell_usage_error([] of String, [] of String, false, "fish", nil, nil, nil).not_nil!
      .should contain("--shell only applies to --print")
    Gori::CLI::Run.shell_usage_error([] of String, [] of String, true, "pwsh", nil, nil, nil).not_nil!
      .should contain("unknown --shell")
    Gori::CLI::Run.shell_usage_error([] of String, [] of String, true, "fish", nil, nil, nil).should be_nil
  end

  it "refuses two answers to where the proxy is" do
    Gori::CLI::Run.shell_usage_error([] of String, [] of String, false, nil, "127.0.0.1:8070", "p", nil).not_nil!
      .should contain("not both")
    Gori::CLI::Run.shell_usage_error([] of String, [] of String, false, nil, nil, "p", "/x.db").not_nil!
      .should contain("not both")
  end

  it "reads --proxy as a dialable authority, tolerating a copied http:// prefix" do
    Gori::CLI::Run.shell_proxy_authority("127.0.0.1:8070").should eq("127.0.0.1:8070")
    Gori::CLI::Run.shell_proxy_authority("http://127.0.0.1:8070/").should eq("127.0.0.1:8070")
    Gori::CLI::Run.shell_proxy_authority("0.0.0.0:8070").should eq("127.0.0.1:8070")
    Gori::CLI::Run.shell_proxy_authority("[::1]:8070").should eq("[::1]:8070")
    Gori::CLI::Run.shell_proxy_authority("localhost:9000").should eq("localhost:9000")
    ["", "127.0.0.1", "127.0.0.1:0", "127.0.0.1:70000", "u:p@127.0.0.1:8070",
     "127.0.0.1:8070/path", "socks5://127.0.0.1:1080"].each do |bad|
      Gori::CLI::Run.shell_proxy_authority(bad).should be_nil, bad
    end
  end

  it "falls back to /bin/sh when $SHELL is unset or not runnable" do
    Gori::CLI::Run.login_shell({"SHELL" => "/bin/sh"}).should eq("/bin/sh")
    Gori::CLI::Run.login_shell({} of String => String).should eq("/bin/sh")
    Gori::CLI::Run.login_shell({"SHELL" => "/no/such/shell"}).should eq("/bin/sh")
    Gori::CLI::Run.login_shell({"SHELL" => "/tmp"}).should eq("/bin/sh")
  end
end

describe "gori run shell — which gori" do
  it "refuses when nothing captures the project, pointing at the way out" do
    with_capture_project do |project, _ca, _root|
      msg = Gori::CLI::Run.shell_target(project, nil, nil).as(String)
      msg.should contain("no gori is capturing shellproj")
      msg.should contain("--proxy HOST:PORT")
    end
  end

  it "does not trust a marker left behind by a gori that is gone" do
    with_capture_project do |project, ca, _root|
      Gori::CaptureStatus.write_at(project.capture_status_path, "127.0.0.1", 8070, true, ca)
      Gori::CLI::Run.shell_target(project, nil, nil).as(String).should contain("no gori is capturing")
    end
  end

  it "points at the LIVE bind and the CA the capturing gori recorded" do
    with_capture_project do |project, ca, _root|
      # The live port, not the configured one: gori falls back when its port is taken.
      Gori::CaptureStatus.write_at(project.capture_status_path, "0.0.0.0", 18_071, true, ca)
      capturing(project) do
        t = target!(Gori::CLI::Run.shell_target(project, nil, nil))
        t.authority.should eq("127.0.0.1:18071")
        t.ca_cert_path.should eq(ca)
        t.label.should contain("shellproj")
        t.warnings.should be_empty
      end
    end
  end

  it "warns but proceeds when capture is paused" do
    with_capture_project do |project, ca, _root|
      Gori::CaptureStatus.write_at(project.capture_status_path, "127.0.0.1", 8070, false, ca)
      capturing(project) do
        t = target!(Gori::CLI::Run.shell_target(project, nil, nil))
        t.warnings.join.should contain("capture is paused")
      end
    end
  end

  it "refuses when the lock is held but no address was published" do
    with_capture_project do |project, _ca, _root|
      capturing(project) do
        Gori::CLI::Run.shell_target(project, nil, nil).as(String).should contain("has not published its address")
      end
    end
  end

  it "prefers --ca-dir over the recorded CA, and refuses a CA that is not there" do
    with_capture_project do |project, ca, root|
      Gori::CaptureStatus.write_at(project.capture_status_path, "127.0.0.1", 8070, true, ca)
      capturing(project) do
        Gori::CLI::Run.shell_target(project, nil, File.join(root, "empty")).as(String)
          .should contain("no gori CA certificate")
        other = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "other"))
        target!(Gori::CLI::Run.shell_target(project, nil, File.join(root, "other"))).ca_cert_path
          .should eq(other.ca_cert_path)
      end
    end
  end

  it "takes --proxy as given without looking for a capture" do
    with_capture_project do |_project, ca, _root|
      t = target!(Gori::CLI::Run.shell_target(nil, "0.0.0.0:9999", File.dirname(ca)))
      t.authority.should eq("127.0.0.1:9999")
      t.ca_cert_path.should eq(ca)
      Gori::CLI::Run.shell_target(nil, "nope", File.dirname(ca)).as(String).should contain("--proxy expects HOST:PORT")
    end
  end

  it "headers --print with how to apply it and what it cannot reach" do
    with_capture_project do |_project, ca, root|
      t = target!(Gori::CLI::Run.shell_target(nil, "127.0.0.1:8070", File.dirname(ca)))
      result = Gori::ShellEnv.build(t.authority, t.ca_cert_path, env: {} of String => String,
        dir: File.join(root, "shell"), system_source: {nil, nil})
      header = Gori::CLI::Run.shell_print_header(result, t).join("\n")
      header.should contain(%(eval "$(gori run shell --print)"))
      header.should contain(result.bundle_path)
      Gori::ShellEnv::CAVEATS.each { |c| header.should contain(c) }
    end
  end

  it "sanitizes the --print header so a hostile project name cannot break out of comments" do
    with_capture_project do |_project, ca, root|
      pwned = File.join(root, "PWNED")
      hostile_target = Gori::CLI::Run::ShellTarget.new("127.0.0.1:8070", ca,
        "demo\ntouch #{pwned}\n# extra on 127.0.0.1:8070", [] of String)
      result = Gori::ShellEnv.build(hostile_target.authority, hostile_target.ca_cert_path,
        env: {} of String => String, dir: File.join(root, "shell"), system_source: {nil, nil})
      text = Gori::ShellEnv.render(result, Gori::ShellEnv::Syntax::Posix,
        header: Gori::CLI::Run.shell_print_header(result, hostile_target))

      # When evaluated by /bin/sh, no commands outside of comments must run
      Process.run("/bin/sh", ["-c", "cd #{root} && eval \"$0\"", text])
      File.exists?(pwned).should be_false
    end
  end
end
